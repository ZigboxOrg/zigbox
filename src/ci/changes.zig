//! Decides what pull-request and merge CI runs, from the event, the head branch, the labels and
//! the changed paths. It is `.github/ci-changes.sh` ported to Zig (docs/decisions/
//! 2026-11-19-ci-on-woodpecker.md); the rules are the same, so
//! docs/decisions/2026-11-04-ci-affected-demos.md still describes them.
//!
//!   code      the build, tidy, test, errors-site, fuzz, fuzz-provenance and dbus-live gates
//!   demo_<d>  one VM demo, <d> in `demo_ids`
//!   demo_m8_packages  the four-guest packages demo (demo-m8-packages): the package sources, the
//!             packaging files and the packages harness (not the m8 demo's own rules)
//!
//! A push to main (any event but a pull request), a pull request from a `claude/release-*`
//! branch, a pull request labelled `full-ci` and a change with no paths at all run everything.
//! A change of docs only runs nothing. Otherwise `rules` pick the demos, in order, first match
//! wins. A path no rule names runs every VM demo, but not the packages demo: that one runs only
//! for the package files, the VM guests, the build and CI itself (docs/demos/m8.md). Rules err
//! toward running. Build-host tooling: it allocates nothing and never touches the host.

const std = @import("std");
const assert = std.debug.assert;
const glob = @import("glob.zig");

/// The VM demos a change can select, in the order the outputs list them. The ids are the names
/// the outputs carry (`demo_s2_lazy`); `demos.zig` maps each to its `zig build` step. A later
/// demo repeats the parts of the earlier ones, which `from` in a rule relies on.
pub const demo_ids = [_][]const u8{
    "m0",  "m1", "m2", "m2b", "m3", "m4",  "m5", "m6",      "m6b",
    "m6d", "m7", "m8", "m8b", "m9", "m10", "c4", "s2_lazy", "s2",
};

/// The packages demo's id: selected on its own, after the others.
pub const packages_id = "m8_packages";

/// Every selectable demo: `demo_ids`, then the packages demo.
pub const selectable_count = demo_ids.len + 1;

comptime {
    assert(selectable_count == 19);
}

/// The index of `id` among the selectable demos (`packages_id` is the last), or null.
pub fn index_of(id: []const u8) ?usize {
    for (demo_ids, 0..) |name, index| {
        if (std.mem.eql(u8, name, id)) return index;
    }
    if (std.mem.eql(u8, id, packages_id)) return demo_ids.len;
    return null;
}

/// What the CI system told us about the change.
pub const Inputs = struct {
    /// `pull_request`, `push`, `manual`, ...: anything but `pull_request` runs everything.
    event: []const u8 = "pull_request",
    /// The pull request's head branch.
    head_ref: []const u8 = "",
    /// The pull request's labels, separated by spaces or commas.
    labels: []const u8 = "",
    /// The changed paths, none of them empty.
    paths: []const []const u8,
};

/// What runs: the code gates, and each selectable demo by `index_of`.
pub const Decision = struct {
    code: bool,
    demos: [selectable_count]bool,

    pub fn demo(decision: *const Decision, id: []const u8) bool {
        // Callers pass an id of `demo_ids` or the packages id.
        const index = index_of(id) orelse unreachable;
        return decision.demos[index];
    }
};

const Kind = enum {
    /// Selects what `only` and `from` name (nothing, if both are empty).
    select,
    /// Every demo but the packages demo.
    all,
    /// Every demo and the packages demo.
    everything,
    /// The packages demo alone.
    packages,
    /// `docs/demos/<id>.md` selects demo `<id>` if it is one.
    demo_doc,
};

const Rule = struct {
    patterns: []const []const u8,
    kind: Kind = .select,
    only: []const []const u8 = &.{},
    /// Selects this demo and every later one (empty: none).
    from: []const u8 = "",
};

/// The path rules, in the order the shell's `case` blocks had them: the first rule that matches a
/// path decides it.
const rules = [_]Rule{
    // The release workflow, its own actions and the signing and refresh scripts run only after a
    // push to main (and the release test jobs on a throwaway key); no demo runs them.
    .{ .patterns = &.{
        ".github/workflows/release.yml",
        ".github/release-sign.sh",
        ".github/release-sign-test.sh",
        ".github/release-prepare-check.sh",
        ".github/release-prepare-test.sh",
        ".github/workflows/package-refresh.yml",
        ".github/package-refresh.sh",
        ".github/package-refresh-test.sh",
        ".github/actions/setup-gh/*",
        ".github/actions/find-draft/*",
        ".github/actions/tap-formula/*",
        ".github/actions/mac-check-zip/*",
        ".github/actions/site-serves/*",
        ".github/site-serves-test.sh",
    } },
    // demo-m6d's gate on the owner's Google setup runs in its job alone.
    .{ .patterns = &.{".github/actions/m6d-setup/*"}, .only = &.{"m6d"} },
    // The driver's own tests never reach a demo (before the next rule, which takes src/ci/*).
    .{ .patterns = &.{"src/ci/*_tests.zig"} },
    // What the harness, the build or CI itself is made of: every demo. The CI driver
    // (src/ci_main.zig, src/ci/*) decides which demo runs and how, and cache.zig what a demo's
    // guest starts from; .woodpecker/* and the step image are the pipelines themselves.
    .{ .patterns = &.{
        "build.zig",
        "build.zig.zon",
        ".github/*",
        ".woodpecker/*",
        "ops/ci/image/*",
        "src/ci_main.zig",
        "src/ci/*",
        "src/testing/vm/cache.zig",
        "vm/*",
        "src/testing/vm/lib/*",
        "src/testing/vm/alpine.zon",
        "src/testing/vm/old_release.zon",
        "src/testing/vm/zbx.lock",
        "src/testing/check.zig",
    }, .kind = .everything },
    // `docs/demos/<id>.md` selects that demo (`demo_doc` looks the id up).
    .{ .patterns = &.{ "docs/demos/m*.md", "docs/demos/c4.md" }, .kind = .demo_doc },
    // The packages demo: the package sources, the packaging files and their harness. They set no
    // demo but demo-m8-packages.
    .{ .patterns = &.{
        "src/package.zig",
        "src/package_*.zig",
        "src/package/*",
        "packaging/*",
        "docs/releases/packaging.md",
        "src/testing/vm/*m8_packages*",
    }, .kind = .packages },
    // Not part of any CI demo: the scripts under ops/ (the owner's setup, the backup box; the
    // step image, ops/ci/image/*, is matched by the rule above), the Mac build, the weekly top-20
    // run, the Z7 check, packaging, docs and the site.
    .{ .patterns = &.{
        "src/mac/*",
        "src/macos_main.zig",
        "src/mac_release.zig",
        "src/testing/mac*",
        "src/testing/vm/*top20*",
        "src/testing/vm/*z7*",
        "src/testing/vm/*s2_probe*",
        "src/testing/vm/*m2b_probe*",
        "ops/*",
        "LICENSE",
        "docs/*",
        "site/*",
        "*.md",
    } },
    // The FUSE kernel test runs in demo-s2-lazy's guest, unlike other tests.
    .{
        .patterns = &.{ "src/fuse/kernel_tests.zig", "src/fuse_kernel_test_root.zig" },
        .only = &.{"s2_lazy"},
    },
    // Tests of the code never reach the zbx binary a demo runs.
    .{ .patterns = &.{
        "src/*_tests.zig",
        "src/*/*_tests.zig",
        "src/fuzz*.zig",
        "src/tidy.zig",
        "src/errors_site.zig",
        "src/size_check.zig",
        "src/testdata/*",
        "src/*/fixtures/*",
    } },
    // A harness file named for a demo (checks_m3.zig, upgrade_m6b.zig, m7_project/): that demo and
    // every later one, which repeat its parts. The files named for no demo are shared.
    .{
        .patterns = &.{ "src/testing/vm/m8b/*", "src/testing/vm/*_m8b.zig" },
        .only = &.{"m8b"},
    },
    .{
        .patterns = &.{ "src/testing/vm/*_m10.zig", "src/testing/vm/m10_fixture/*" },
        .only = &.{"m10"},
    },
    // M2b's harness and numa-probe. Its knobs (src/runtime/policy/*, the plan, the child,
    // src/doctor.zig) fall through to the default, which includes m2b.
    .{
        .patterns = &.{ "src/testing/vm/*_m2b.zig", "src/testing/vm/numa_probe/*" },
        .only = &.{"m2b"},
    },
    // main_m2b.zig imports these later demos' checks (its upgrade step, and the files they
    // import): demo-m2b as well as their own demo and every later one.
    .{ .patterns = &.{"src/testing/vm/checks_m3.zig"}, .only = &.{"m2b"}, .from = "m3" },
    .{ .patterns = &.{"src/testing/vm/checks_m4.zig"}, .only = &.{"m2b"}, .from = "m4" },
    .{ .patterns = &.{"src/testing/vm/checks_upgrade_m5.zig"}, .only = &.{"m2b"}, .from = "m5" },
    .{
        .patterns = &.{"src/testing/vm/checks_upgrade_m6b.zig"},
        .only = &.{"m2b"},
        .from = "m6b",
    },
    .{
        .patterns = &.{ "src/testing/vm/*_m6d.zig", "src/testing/vm/m6d_fixture/*" },
        .only = &.{"m6d"},
    },
    .{ .patterns = &.{"src/testing/vm/*_s2_lazy.zig"}, .only = &.{"s2_lazy"} },
    // demo-s2's harness: the disk-backed registry, the fixture generator and the script.
    .{ .patterns = &.{ "src/testing/vm/*_s2.zig", "src/testing/vm/s2/*" }, .only = &.{"s2"} },
    // fixture_http.zig is the HTTP server demo-m9's fetch step runs in the guest; no other uses it.
    .{
        .patterns = &.{
            "src/testing/vm/m9_*",
            "src/testing/vm/*_m9.zig",
            "src/testing/vm/fixture_http.zig",
        },
        .only = &.{"m9"},
    },
    .{
        .patterns = &.{
            "src/testing/vm/*_c4.zig",
            "src/testing/vm/c4/*",
            "src/testing/vm/c4_fixture/*",
        },
        .only = &.{"c4"},
    },
    .{ .patterns = &.{ "src/testing/vm/*_m8.zig", "src/testing/vm/m8_*" }, .only = &.{"m8"} },
    .{ .patterns = &.{ "src/testing/vm/m7_*", "src/testing/vm/*_m7.zig" }, .from = "m7" },
    .{ .patterns = &.{"src/testing/vm/*_m6b.zig"}, .from = "m6b" },
    .{ .patterns = &.{"src/testing/vm/*_m6.zig"}, .from = "m6" },
    .{ .patterns = &.{"src/testing/vm/*_m5.zig"}, .from = "m5" },
    .{ .patterns = &.{"src/testing/vm/*_m4.zig"}, .from = "m4" },
    .{ .patterns = &.{"src/testing/vm/*_m3.zig"}, .from = "m3" },
    .{ .patterns = &.{"src/testing/vm/*_m2.zig"}, .from = "m2" },
    .{ .patterns = &.{"src/testing/vm/*_m1.zig"}, .from = "m1" },
    // The source areas only some demos exercise. Anything else under src/ is the runtime every
    // demo runs on. The Dockerfile translator and its fixtures (demo-m9's ACCEPT imports them)
    // are M9's; the builder under them is M7's and M9's, which builds what it imports.
    .{
        .patterns = &.{ "src/dockerfile/*", "src/import_*.zig", "src/build/dockerfile_fixtures/*" },
        .only = &.{"m9"},
    },
    .{ .patterns = &.{ "src/build/*", "src/build_commands.zig" }, .only = &.{ "m7", "m9" } },
    // Every zbx start sets up the lazy server (main.zig) and links the FUSE host (host_real.zig);
    // pull parses the lazy index's anchors and pack and export import the lazy writer, so these
    // reach the demos from m4 on as well as S2's.
    .{ .patterns = &.{ "src/fuse/lazy_server.zig", "src/host_real_fuse.zig" }, .kind = .all },
    .{ .patterns = &.{"src/lazy/*"}, .from = "m4" },
    .{ .patterns = &.{"src/fuse/*"}, .only = &.{ "s2_lazy", "s2" } },
    .{ .patterns = &.{ "src/trust/*", "src/push/*" }, .only = &.{"m8"} },
    // Every pull asks the Google credential code whether a reference is Artifact Registry's.
    .{
        .patterns = &.{
            "src/registry/*",
            "src/pull*.zig",
            "src/lock_*.zig",
            "src/google/*",
            "src/cloud/*",
        },
        .from = "m4",
    },
    .{ .patterns = &.{ "src/state/*", "src/*state*.zig" }, .from = "m6" },
    .{
        .patterns = &.{
            "src/exec_commands.zig",
            "src/logs_commands.zig",
            "src/runtime/exec*",
            "src/runtime/logfile.zig",
        },
        .from = "m6b",
    },
    // Not src/doctor.zig: `doctor.subid_answer` chooses the id map of every container.
    .{ .patterns = &.{ "src/doctor_fixtures.zig", "src/image_diagnose.zig" }, .only = &.{"m0"} },
};

const Wanted = [selectable_count]bool;

fn select_from(wanted: *Wanted, id: []const u8) void {
    const first = index_of(id) orelse unreachable; // Rules name only ids of `demo_ids`.
    assert(first < demo_ids.len);
    for (first..demo_ids.len) |index| wanted[index] = true;
}

fn select_all(wanted: *Wanted) void {
    for (0..demo_ids.len) |index| wanted[index] = true;
}

fn apply(wanted: *Wanted, rule: *const Rule, path: []const u8) void {
    switch (rule.kind) {
        .all => select_all(wanted),
        .everything => {
            select_all(wanted);
            wanted[demo_ids.len] = true;
        },
        .packages => wanted[demo_ids.len] = true,
        .demo_doc => {
            const suffix = path["docs/demos/".len .. path.len - ".md".len];
            if (index_of(suffix)) |index| {
                if (index < demo_ids.len) wanted[index] = true;
            }
        },
        .select => {
            // Ids of `demo_ids`.
            for (rule.only) |id| wanted[index_of(id) orelse unreachable] = true;
            if (rule.from.len > 0) select_from(wanted, rule.from);
        },
    }
}

/// Marks the demos one changed path can affect. The first matching rule decides; a path no rule
/// names selects every demo but the packages demo.
fn classify(wanted: *Wanted, path: []const u8) void {
    assert(path.len > 0);
    for (&rules) |*rule| {
        if (glob.matches_any(rule.patterns, path)) {
            apply(wanted, rule, path);
            return;
        }
    }
    select_all(wanted);
}

/// Docs only: a .md outside src/, or anything under site/ outside site/errors/ (the error pages
/// are generated from the diagnostic registry and checked by the errors-site gate).
fn is_docs(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "src/")) return false;
    if (std.mem.startsWith(u8, path, "site/errors/")) return false;
    if (std.mem.startsWith(u8, path, "site/")) return true;
    return std.mem.endsWith(u8, path, ".md");
}

fn label_present(labels: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, labels, " ,");
    while (it.next()) |label| {
        if (std.mem.eql(u8, label, wanted)) return true;
    }
    return false;
}

/// True when the event, the branch or the labels ask for everything, whatever the paths say.
fn runs_everything(inputs: *const Inputs) bool {
    // Any other event runs everything: a push to main, a manual run, and Woodpecker's
    // `pull_request_metadata` (a label added, so `full-ci`; it carries no changed paths).
    if (!std.mem.eql(u8, inputs.event, "pull_request")) return true;
    if (std.mem.startsWith(u8, inputs.head_ref, "claude/release-")) return true;
    if (label_present(inputs.labels, "full-ci")) return true;
    // No changed paths at all (a push with an empty diff) is not "docs only": run everything.
    return inputs.paths.len == 0;
}

pub fn decide(inputs: Inputs) Decision {
    if (runs_everything(&inputs)) {
        return .{ .code = true, .demos = @splat(true) };
    }
    var wanted: Wanted = @splat(false);
    var docs_only = true;
    for (inputs.paths) |path| {
        assert(path.len > 0);
        if (!is_docs(path)) docs_only = false;
        classify(&wanted, path);
    }
    if (docs_only) return .{ .code = false, .demos = @splat(false) };
    return .{ .code = true, .demos = wanted };
}

/// Writes the decision as `name=true|false` lines, GitHub's step-output format: `code`, each
/// `demo_<id>`, then `demo_m8_packages`.
pub fn write_outputs(writer: *std.Io.Writer, decision: *const Decision) std.Io.Writer.Error!void {
    try writer.print("code={}\n", .{decision.code});
    for (demo_ids, 0..) |id, index| {
        try writer.print("demo_{s}={}\n", .{ id, decision.demos[index] });
    }
    try writer.print("demo_{s}={}\n", .{ packages_id, decision.demos[demo_ids.len] });
}

test "changes: every rule names only demos that exist" {
    // Goal: a typo in a rule's demo id would make `apply` hit its `unreachable` in CI. Method:
    // walk the table and look every id up.
    for (&rules) |*rule| {
        try std.testing.expect(rule.patterns.len > 0);
        for (rule.only) |id| {
            const index = index_of(id) orelse return error.UnknownDemo;
            try std.testing.expect(index < demo_ids.len);
        }
        if (rule.from.len > 0) {
            const index = index_of(rule.from) orelse return error.UnknownDemo;
            try std.testing.expect(index < demo_ids.len);
        }
    }
    try std.testing.expectEqual(@as(?usize, demo_ids.len), index_of(packages_id));
    try std.testing.expectEqual(@as(?usize, null), index_of("m11"));
}

test "changes: the event, branch, labels and paths that run everything" {
    // Goal: the rules AGENTS.md states for full runs and for docs-only changes, which the path
    // table (changes_tests.zig) does not reach. Method: one decision per case.
    const docs: []const []const u8 = &.{"README.md"};
    const code: []const []const u8 = &.{"src/package.zig"};
    const none: []const []const u8 = &.{};
    // A docs-only pull request runs nothing.
    const quiet = decide(.{ .paths = docs });
    try std.testing.expect(!quiet.code);
    for (quiet.demos) |on| try std.testing.expect(!on);
    // A push to main, a manual run, a release branch, the full-ci label: everything, even docs.
    const loud = [_]Decision{
        decide(.{ .event = "push", .paths = docs }),
        decide(.{ .event = "manual", .paths = docs }),
        decide(.{ .head_ref = "claude/release-0.6", .paths = docs }),
        decide(.{ .labels = "bug full-ci", .paths = docs }),
        decide(.{ .labels = "bug,full-ci", .paths = docs }),
        decide(.{ .paths = none }),
    };
    for (loud) |decision| {
        try std.testing.expect(decision.code);
        for (decision.demos) |on| try std.testing.expect(on);
    }
    // A label that only contains the word, and a branch that only resembles it, do not count.
    const near = decide(.{ .head_ref = "claude/release", .labels = "not-full-ci", .paths = code });
    try std.testing.expect(near.code);
    try std.testing.expect(near.demo("m8_packages"));
    try std.testing.expect(!near.demo("m0"));
}

test "changes: outputs are code, the demos in order, then the packages demo" {
    // Goal: the output format both CI systems read. Method: render one decision and compare.
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const decision = decide(.{ .paths = &.{"src/doctor_fixtures.zig"} });
    try write_outputs(&writer, &decision);
    const text = writer.buffered();
    const head = "code=true\ndemo_m0=true\ndemo_m1=false\n";
    try std.testing.expect(std.mem.startsWith(u8, text, head));
    const tail = "demo_s2_lazy=false\ndemo_s2=false\ndemo_m8_packages=false\n";
    try std.testing.expect(std.mem.endsWith(u8, text, tail));
    try std.testing.expectEqual(@as(usize, selectable_count + 1), std.mem.count(u8, text, "\n"));
}
