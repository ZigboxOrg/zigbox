//! `build_old <zig> <commit> <output>`: builds the x86_64 release `zbx` of an older commit, for
//! the upgrade test of `zig build demo-m3`. A git worktree of <commit> under `.zig-cache`,
//! `zig build release` in it (the same pinned Zig), and the stripped binary copied to <output>.
//! A commit missing from the clone is fetched from origin's old/* branches and tags first.
//! Build-host tool, run by build.zig from the repository root.

const std = @import("std");
const Io = std.Io;

/// Where the pinned commits of `old_release.zon` live on origin: the old/* branches and the tags.
const fetch_branches = "+refs/heads/old/*:refs/remotes/origin/old/*";
/// Tags go to a private namespace, not refs/tags/*: a developer's own tag of the same name is
/// never overwritten, and `git cat-file` finds the commit through the fetched objects either way.
const fetch_tags = "refs/tags/*:refs/zbx-old/tags/*";

/// A stalled connection gives up after a minute below 1 KB/s, and the whole fetch after 20.
const fetch_timeout_seconds = "1200";

/// One worktree for each commit, so that two demos can build their older releases at once.
fn tree_path(arena: std.mem.Allocator, commit: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/zbx-old-tree-{s}", .{commit});
}

/// Runs `argv` (in `cwd` if given), its output on stderr, and fails unless it exits 0.
fn run(io: Io, argv: []const []const u8, cwd: ?[]const u8, quiet: bool) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout = .ignore,
        .stderr = if (quiet) .ignore else .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

fn succeeds(io: Io, argv: []const []const u8) bool {
    run(io, argv, null, true) catch return false;
    return true;
}

/// The name git can check out for `commit`: the pin itself, or after a fetch from origin its tag in
/// the private namespace. Null (after saying why on `err`) when it is not there to be had.
fn find_commit(init: std.process.Init, err: *Io.Writer, commit: []const u8) !?[]const u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const pin = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{commit});
    if (succeeds(io, &.{ "git", "cat-file", "-e", pin })) return commit;
    // A clone of one ref (Woodpecker's clone, a shallow checkout) lacks the pinned commits:
    // they live on origin's old/* branches and release tags, not on main.
    try err.print("build_old: {s} is not in this clone; fetching {s} and {s}\n", .{
        commit, fetch_branches, fetch_tags,
    });
    try err.flush();
    const fetch = [_][]const u8{
        "timeout",                 fetch_timeout_seconds,
        "git",                     "-c",
        "http.lowSpeedLimit=1000", "-c",
        "http.lowSpeedTime=60",    "fetch",
        "--quiet",                 "origin",
        fetch_branches,            fetch_tags,
    };
    run(io, &fetch, null, false) catch {
        try err.print("build_old: fetching origin's old/* branches and tags failed (network, " ++
            "or git is missing); {s} may well be there, so try again\n", .{commit});
        return null;
    };
    if (succeeds(io, &.{ "git", "cat-file", "-e", pin })) return commit;
    const private = try std.fmt.allocPrint(arena, "refs/zbx-old/tags/{s}", .{commit});
    const private_pin = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{private});
    if (succeeds(io, &.{ "git", "cat-file", "-e", private_pin })) return private;
    try err.print("build_old: {s} is neither in this clone nor on origin's old/* " ++
        "branches or tags, so the older release cannot be built; push it to origin " ++
        "(a tag: git push origin {s}) or pin a commit that is there in " ++
        "src/testing/vm/old_release.zon\n", .{ commit, commit });
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    var buffer: [512]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stderr(), init.io, &buffer);
    const err = &file_writer.interface;
    defer err.flush() catch {};
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const zig = arguments.next() orelse return usage(err);
    const commit = arguments.next() orelse return usage(err);
    const output = arguments.next() orelse return usage(err);
    const io = init.io;
    const tree = try tree_path(init.arena.allocator(), commit);
    const rev = try find_commit(init, err, commit) orelse return 1;
    try run(io, &.{ "git", "worktree", "prune" }, null, false);
    if (Io.Dir.cwd().access(io, tree, .{})) |_| {} else |_| {
        const add = [_][]const u8{
            "git",      "worktree", "add", "--quiet", "--force",
            "--detach", tree,       rev,
        };
        try run(io, &add, null, false);
    }
    try run(io, &.{ "git", "-C", tree, "checkout", "--quiet", "--detach", rev }, null, false);
    try run(io, &.{ zig, "build", "release" }, tree, false);
    const built = try std.fmt.allocPrint(
        init.arena.allocator(),
        "{s}/zig-out/release/x86_64-linux/zbx",
        .{tree},
    );
    try Io.Dir.cwd().copyFile(built, Io.Dir.cwd(), output, io, .{});
    return 0;
}

fn usage(err: *Io.Writer) !u8 {
    try err.print("usage: build_old <zig> <commit> <output>\n", .{});
    return 2;
}
