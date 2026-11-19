//! `ci`: what the self-hosted CI (Woodpecker, `.woodpecker/`) and ci.yml's `changes` job run. It
//! is the build's, not the YAML's: `zig build ci-changes`, `ci-build`, `ci-tidy`, `ci-test`,
//! `ci-errors-site`, `ci-fuzz`, `ci-fuzz-provenance`, `ci-dbus-live`, `ci-demos` and `vm-branch`
//! run this program with the build's own `zig` (docs/decisions/2026-11-19-ci-on-woodpecker.md).
//!
//!   ci --zig ZIG changes                 print (and with --output append) the decision
//!   ci --zig ZIG gate NAME               run one gate if the change touches code
//!   ci --zig ZIG demos [--demo ID]       run the demos the change can affect, or one if it can
//!   ci --zig ZIG vm-branch vm/DEMO-SLUG  run that scratch branch's demos, then delete the branch
//!
//! Every command takes the change: `--event`, `--branch`, `--labels`, and the changed paths as
//! `--files TEXT` (one per line), `--files-json JSON` or `--stdin`; each falls back to Woodpecker's
//! `CI_PIPELINE_EVENT`, `CI_COMMIT_SOURCE_BRANCH`, `CI_COMMIT_PULL_REQUEST_LABELS` and
//! `CI_PIPELINE_FILES`. The rules are `ci/changes.zig`. Other flags: `--accel` (default kvm),
//! `--vm-cache DIR` (or `ZBX_VM_CACHE`; testing/vm/cache.zig), `--output FILE`, `--repo OWNER/NAME`
//! and `--api-url URL` (vm-branch). Environment: `GITHUB_TOKEN` (vm-branch); `ZBX_CI_USER`, when
//! this runs as root, runs the work as that user with `ZBX_CI_USER_ZIG_CACHE` as its Zig cache
//! (the box's steps run as root in the workspace; the work runs as an ordinary user, as on GitHub's
//! runners, and the workspace is handed to that user first).
//!
//! A gate or demo the change cannot affect prints one line saying so and passes. Build-host
//! tooling: it spawns `zig`, `runuser` and `chown` and never touches the host otherwise.

const std = @import("std");
const Io = std.Io;
const changes = @import("ci/changes.zig");
const demos = @import("ci/demos.zig");
const cache_store = @import("testing/vm/cache.zig");

const Args = struct {
    zig: []const u8 = "zig",
    command: []const u8 = "",
    positional: ?[]const u8 = null,
    event: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    files: ?[]const u8 = null,
    files_json: ?[]const u8 = null,
    stdin: bool = false,
    output: ?[]const u8 = null,
    demo: ?[]const u8 = null,
    accel: []const u8 = "kvm",
    vm_cache: ?[]const u8 = null,
    api_url: []const u8 = "https://api.github.com",
    repo: ?[]const u8 = null,
};

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    args: Args,
    out: *Io.Writer,

    fn say(ctx: *Ctx, comptime format: []const u8, values: anytype) void {
        ctx.out.print("ci: " ++ format ++ "\n", values) catch {};
        ctx.out.flush() catch {};
    }
};

const usage_text =
    "usage: ci --zig ZIG changes | gate NAME | demos [--demo ID] | vm-branch vm/DEMO-SLUG " ++
    "[--event E] [--branch B] [--labels L] [--files TEXT | --files-json JSON | --stdin] " ++
    "[--accel A] [--vm-cache DIR] [--output FILE] [--repo OWNER/NAME] [--api-url URL]\n";

pub fn main(init: std.process.Init) !u8 {
    var buffer: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    var args: Args = .{};
    parse_args(&arguments, &args) catch {
        try writer.interface.writeAll(usage_text);
        try writer.interface.flush();
        return 2;
    };
    var ctx: Ctx = .{
        .io = init.io,
        .gpa = init.arena.allocator(),
        .env = init.environ_map,
        .args = args,
        .out = &writer.interface,
    };
    const status = run_command(&ctx) catch |err| {
        ctx.say("{s}: {s}", .{ args.command, @errorName(err) });
        return 1;
    };
    try writer.interface.flush();
    return status;
}

fn parse_args(arguments: anytype, args: *Args) !void {
    while (arguments.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (args.command.len == 0) {
                args.command = arg;
            } else if (args.positional == null) {
                args.positional = arg;
            } else return error.Usage;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdin")) {
            args.stdin = true;
            continue;
        }
        const value = arguments.next() orelse return error.Usage;
        try set_flag(args, arg, value);
    }
}

fn set_flag(args: *Args, flag: []const u8, value: []const u8) !void {
    const names = .{
        .{ "--zig", "zig" },         .{ "--event", "event" },
        .{ "--branch", "branch" },   .{ "--labels", "labels" },
        .{ "--files", "files" },     .{ "--files-json", "files_json" },
        .{ "--output", "output" },   .{ "--demo", "demo" },
        .{ "--accel", "accel" },     .{ "--vm-cache", "vm_cache" },
        .{ "--api-url", "api_url" }, .{ "--repo", "repo" },
    };
    inline for (names) |pair| {
        if (std.mem.eql(u8, flag, pair[0])) {
            @field(args, pair[1]) = value;
            return;
        }
    }
    return error.Usage;
}

fn run_command(ctx: *Ctx) !u8 {
    const command = ctx.args.command;
    if (std.mem.eql(u8, command, "changes")) return cmd_changes(ctx);
    if (std.mem.eql(u8, command, "gate")) return cmd_gate(ctx);
    if (std.mem.eql(u8, command, "demos")) return cmd_demos(ctx);
    if (std.mem.eql(u8, command, "vm-branch")) return cmd_vm_branch(ctx);
    try ctx.out.writeAll(usage_text);
    return 2;
}

// What changed.

/// Splits `text` into its non-empty lines.
fn lines_of(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| try list.append(gpa, line);
    return list.items;
}

/// The paths of a JSON array of strings (Woodpecker's `CI_PIPELINE_FILES`), without empty ones.
fn paths_of_json(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    if (std.mem.trim(u8, text, " \r\n").len == 0) return &.{};
    const parsed = try std.json.parseFromSlice([]const []const u8, gpa, text, .{});
    var list: std.ArrayList([]const u8) = .empty;
    for (parsed.value) |path| {
        if (path.len > 0) try list.append(gpa, path);
    }
    return list.items;
}

fn paths_of_stdin(ctx: *Ctx) ![]const []const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(ctx.io, &buffer);
    const text = try reader.interface.allocRemaining(ctx.gpa, .limited(1 << 20));
    return lines_of(ctx.gpa, text);
}

fn change_paths(ctx: *Ctx) ![]const []const u8 {
    if (ctx.args.files) |text| return lines_of(ctx.gpa, text);
    if (ctx.args.files_json) |text| return paths_of_json(ctx.gpa, text);
    if (ctx.args.stdin) return paths_of_stdin(ctx);
    return paths_of_json(ctx.gpa, ctx.env.get("CI_PIPELINE_FILES") orelse "");
}

fn decide(ctx: *Ctx) !changes.Decision {
    const args = &ctx.args;
    return changes.decide(.{
        .event = args.event orelse ctx.env.get("CI_PIPELINE_EVENT") orelse "pull_request",
        .head_ref = args.branch orelse ctx.env.get("CI_COMMIT_SOURCE_BRANCH") orelse "",
        .labels = args.labels orelse ctx.env.get("CI_COMMIT_PULL_REQUEST_LABELS") orelse "",
        .paths = try change_paths(ctx),
    });
}

fn cmd_changes(ctx: *Ctx) !u8 {
    const decision = try decide(ctx);
    var text: Io.Writer.Allocating = .init(ctx.gpa);
    try changes.write_outputs(&text.writer, &decision);
    try ctx.out.writeAll(text.written());
    if (ctx.args.output) |path| try append_file(ctx, path, text.written());
    return 0;
}

fn append_file(ctx: *Ctx, path: []const u8, bytes: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = false });
    defer file.close(ctx.io);
    try file.writePositionalAll(ctx.io, bytes, try file.length(ctx.io));
}

// Running the work.

/// The user the work runs as: `ZBX_CI_USER`, when this process is root and can hand it the
/// workspace; otherwise null and the work runs as this process.
fn work_user(ctx: *Ctx) ?[]const u8 {
    const user = ctx.env.get("ZBX_CI_USER") orelse return null;
    if (user.len == 0) return null;
    if (std.os.linux.geteuid() != 0) return null;
    return user;
}

/// Runs `argv` with the work's user and environment (`extra` adds variables), output inherited;
/// fails unless it exits 0.
fn exec(ctx: *Ctx, extra: []const []const u8, argv: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    if (work_user(ctx)) |user| try append_user_prefix(ctx, &full, user);
    if (work_user(ctx) == null and extra.len > 0) try full.append(ctx.gpa, "env");
    try full.appendSlice(ctx.gpa, extra);
    try full.appendSlice(ctx.gpa, argv);
    ctx.say("$ {s}", .{try std.mem.join(ctx.gpa, " ", argv)});
    try wait_ok(ctx, full.items, .inherit);
}

/// `runuser -u USER -- env HOME=... ZIG_GLOBAL_CACHE_DIR=... ZIG_LOCAL_CACHE_DIR=...`: the work's
/// own home and Zig caches, apart from the root build's that is running this driver.
fn append_user_prefix(ctx: *Ctx, full: *std.ArrayList([]const u8), user: []const u8) !void {
    const cache = ctx.env.get("ZBX_CI_USER_ZIG_CACHE") orelse
        try std.fmt.allocPrint(ctx.gpa, "/home/{s}/.cache/zig", .{user});
    const gpa = ctx.gpa;
    try full.appendSlice(gpa, &.{ "runuser", "-u", user, "--", "env" });
    try full.append(gpa, try std.fmt.allocPrint(gpa, "HOME=/home/{s}", .{user}));
    try full.append(gpa, try std.fmt.allocPrint(gpa, "ZIG_GLOBAL_CACHE_DIR={s}", .{cache}));
    try full.append(gpa, try std.fmt.allocPrint(gpa, "ZIG_LOCAL_CACHE_DIR={s}/local", .{cache}));
}

fn wait_ok(ctx: *Ctx, argv: []const []const u8, stdout: std.process.SpawnOptions.StdIo) !void {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = stdout,
        .stderr = .inherit,
    });
    switch (try child.wait(ctx.io)) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

/// Hands the workspace to the work's user (a checkout made by root is not theirs to write).
fn hand_over_workspace(ctx: *Ctx) !void {
    const user = work_user(ctx) orelse return;
    try wait_ok(ctx, &.{ "chown", "-R", user, "." }, .ignore);
}

fn zig_build(ctx: *Ctx, extra: []const []const u8, tail: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.gpa, &.{ ctx.args.zig, "build" });
    try argv.appendSlice(ctx.gpa, tail);
    try exec(ctx, extra, argv.items);
}

// Gates.

const Gate = enum { build, tidy, @"test", @"errors-site", fuzz, @"fuzz-provenance", @"dbus-live" };

fn cmd_gate(ctx: *Ctx) !u8 {
    const name = ctx.args.positional orelse return error.Usage;
    const gate = std.meta.stringToEnum(Gate, name) orelse {
        ctx.say("no gate {s}", .{name});
        return 1;
    };
    const decision = try decide(ctx);
    if (!decision.code) {
        ctx.say("{s}: skipped, this change touches no code (docs only)", .{name});
        return 0;
    }
    try hand_over_workspace(ctx);
    try run_gate(ctx, gate);
    return 0;
}

fn run_gate(ctx: *Ctx, gate: Gate) !void {
    switch (gate) {
        .build => {
            try zig_build(ctx, &.{}, &.{});
            try zig_build(ctx, &.{}, &.{"release"});
            try zig_build(ctx, &.{}, &.{"trust-wasm"});
            try zig_build(ctx, &.{}, &.{"fuzz-macos"});
        },
        .tidy => try zig_build(ctx, &.{}, &.{"tidy"}),
        .@"test" => try zig_build(ctx, &.{}, &.{ "test", "--summary", "all" }),
        .@"errors-site" => try zig_build(ctx, &.{}, &.{"errors-site-check"}),
        .fuzz => try zig_build(ctx, &.{}, &.{ "fuzz", "--", "all-but", "provenance", "10000" }),
        .@"fuzz-provenance" => try run_provenance(ctx),
        // The session bus the dbus tests talk to lives only as long as this command.
        .@"dbus-live" => try exec(ctx, &.{}, &.{
            "dbus-run-session", "--", ctx.args.zig, "build", "dbus-live",
        }),
    }
}

/// The slow fuzzer, on a random seed that is printed so a failure replays.
fn run_provenance(ctx: *Ctx) !void {
    var seed: [8]u8 = undefined;
    ctx.io.random(&seed);
    const text = try std.fmt.allocPrint(ctx.gpa, "{d}", .{std.mem.readInt(u64, &seed, .little)});
    ctx.say("fuzz-provenance: seed {s}", .{text});
    try zig_build(ctx, &.{}, &.{ "fuzz", "--", "provenance", text, "10000" });
}

// Demos.

fn cmd_demos(ctx: *Ctx) !u8 {
    const decision = try decide(ctx);
    if (ctx.args.demo) |id| {
        const index = changes.index_of(id) orelse {
            ctx.say("no demo {s}", .{id});
            return 1;
        };
        if (!decision.demos[index]) {
            ctx.say("demo {s}: skipped, this change cannot affect it", .{id});
            return 0;
        }
        return run_ids(ctx, &.{id});
    }
    var ids: std.ArrayList([]const u8) = .empty;
    for (changes.demo_ids ++ [_][]const u8{changes.packages_id}, 0..) |id, index| {
        if (decision.demos[index]) try ids.append(ctx.gpa, id);
    }
    if (ids.items.len == 0) {
        ctx.say("demos: skipped, this change cannot affect any VM demo", .{});
        return 0;
    }
    return run_ids(ctx, ids.items);
}

/// Runs each id's plan: the steps that run together (so the cache is restored once), and a line
/// for each that does not run. Exit status 1 if any step failed.
fn run_ids(ctx: *Ctx, ids: []const []const u8) !u8 {
    var run: std.ArrayList([]const u8) = .empty;
    for (ids) |id| {
        switch (demos.plan_for_id(id).?) {
            .run => |steps| try run.appendSlice(ctx.gpa, steps),
            .not_run => |why| ctx.say("demo {s}: NOT RUN ({s})", .{ id, why }),
        }
    }
    return run_steps(ctx, run.items);
}

fn vm_cache_dir(ctx: *Ctx) ?[]const u8 {
    if (ctx.args.vm_cache) |path| return path;
    const path = ctx.env.get("ZBX_VM_CACHE") orelse return null;
    return if (path.len > 0) path else null;
}

/// Runs the demo steps as the work's user, each a nested `zig build STEP -Daccel=...`, with the VM
/// cache restored before and saved after when one is set. Returns 1 if any step failed.
fn run_steps(ctx: *Ctx, steps: []const []const u8) !u8 {
    if (steps.len == 0) return 0;
    if (std.mem.eql(u8, ctx.args.accel, "kvm")) {
        Io.Dir.cwd().access(ctx.io, "/dev/kvm", .{ .write = true }) catch {
            ctx.say("/dev/kvm is not writable: the demos need KVM (repository Trusted?)", .{});
            return 1;
        };
    }
    var store: ?Io.Dir = null;
    defer if (store) |dir| dir.close(ctx.io);
    var cache: cache_store.Cache = undefined;
    if (vm_cache_dir(ctx)) |path| {
        try Io.Dir.cwd().createDirPath(ctx.io, path);
        store = try Io.Dir.cwd().openDir(ctx.io, path, .{});
        cache = .{ .io = ctx.io, .workspace = Io.Dir.cwd(), .store = store.?, .log = ctx.out };
        cache_store.restore(&cache, &cache_store.entries);
    }
    try hand_over_workspace(ctx);
    var failed = false;
    for (steps) |step| {
        ctx.say("== {s}", .{step});
        run_step(ctx, step) catch {
            ctx.say("{s}: FAILED", .{step});
            failed = true;
        };
    }
    if (store != null) cache_store.save(&cache, &cache_store.entries);
    return @intFromBool(failed);
}

fn run_step(ctx: *Ctx, step: []const u8) !void {
    const accel = try std.fmt.allocPrint(ctx.gpa, "-Daccel={s}", .{ctx.args.accel});
    const extra: []const []const u8 = if (demos.needs_mirror(step))
        &.{"ZBX_REGISTRY_MIRRORS=mirror.gcr.io"}
    else
        &.{};
    try zig_build(ctx, extra, &.{ step, accel });
}

// Scratch branches.

fn cmd_vm_branch(ctx: *Ctx) !u8 {
    const branch = ctx.args.positional orelse return error.Usage;
    if (!std.mem.startsWith(u8, branch, "vm/")) {
        ctx.say("{s} is not a vm/<demo>-<slug> branch", .{branch});
        return 1;
    }
    const plan = demos.plan_for_branch(branch["vm/".len..]) orelse {
        ctx.say("branch {s} names no demo (vm/<demo>-<slug>; see ci/demos.zig)", .{branch});
        delete_branch(ctx, branch);
        return 1;
    };
    var status: u8 = 0;
    switch (plan) {
        .run => |steps| status = try run_steps(ctx, steps),
        .not_run => |why| ctx.say("{s}: NOT RUN ({s})", .{ branch, why }),
    }
    delete_branch(ctx, branch);
    return status;
}

/// Deletes `branch` through the GitHub REST API; says what happened and never fails: with no
/// `GITHUB_TOKEN` the branch stays.
fn delete_branch(ctx: *Ctx, branch: []const u8) void {
    const token = ctx.env.get("GITHUB_TOKEN") orelse "";
    if (token.len == 0) {
        ctx.say("not deleting {s}: GITHUB_TOKEN is not set, so the branch stays", .{branch});
        return;
    }
    const repo = ctx.args.repo orelse ctx.env.get("CI_REPO") orelse {
        ctx.say("not deleting {s}: no repository (--repo OWNER/NAME or CI_REPO)", .{branch});
        return;
    };
    const status = request_delete(ctx, repo, branch, token) catch |err| {
        ctx.say("could not delete {s}: {s}", .{ branch, @errorName(err) });
        return;
    };
    switch (status) {
        .no_content => ctx.say("deleted the scratch branch {s}", .{branch}),
        // GitHub answers 422 "Reference does not exist" when the branch is already gone (another
        // runner deleted it first, or a newer push's run did).
        .unprocessable_entity => ctx.say("{s} was already deleted", .{branch}),
        .unauthorized, .forbidden, .not_found => ctx.say(
            "could not delete {s}: GitHub answered {d} (the token needs contents: write)",
            .{ branch, @backingInt(status) },
        ),
        else => ctx.say("could not delete {s}: GitHub answered {d}", .{
            branch, @backingInt(status),
        }),
    }
}

fn request_delete(
    ctx: *Ctx,
    repo: []const u8,
    branch: []const u8,
    token: []const u8,
) !std.http.Status {
    const gpa = ctx.gpa;
    const url = try std.fmt.allocPrint(gpa, "{s}/repos/{s}/git/refs/heads/{s}", .{
        ctx.args.api_url, repo, branch,
    });
    var client: std.http.Client = .{ .allocator = gpa, .io = ctx.io };
    defer client.deinit();
    try client.initDefaultProxies(gpa, ctx.env);
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .DELETE,
        .headers = .{
            .authorization = .{ .override = bearer },
            .user_agent = .{ .override = "zigbox-ci" },
        },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
    });
    return result.status;
}

test {
    // The tests of the rules and of the cache the driver uses.
    _ = @import("ci/changes_tests.zig");
    _ = @import("ci/demos.zig");
    _ = @import("testing/vm/cache.zig");
}

test "ci: change inputs are read as lines and as a JSON array" {
    // Goal: the two forms the CI systems give the changed paths. Method: parse each.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const lines = try lines_of(gpa, "a.zig\r\n\nb/c.md\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("b/c.md", lines[1]);
    const json = try paths_of_json(gpa, "[\"a.zig\",\"\",\"b/c.md\"]");
    try std.testing.expectEqual(@as(usize, 2), json.len);
    try std.testing.expectEqual(@as(usize, 0), (try paths_of_json(gpa, "[]")).len);
    try std.testing.expectEqual(@as(usize, 0), (try paths_of_json(gpa, "")).len);
}
