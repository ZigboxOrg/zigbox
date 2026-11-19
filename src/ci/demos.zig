//! Which `zig build` steps run a VM demo: the demos `changes.zig` selects (by id) and the
//! scratch branches `vm/<demo>-<slug>` (the names `.github/workflows/vm.yml` takes). Pure
//! tables and lookups; `ci_main.zig` runs what they name.

const std = @import("std");
const assert = std.debug.assert;
const changes = @import("changes.zig");

/// What a demo id or branch name resolves to.
pub const Plan = union(enum) {
    /// These `zig build` steps, in order.
    run: []const []const u8,
    /// Nothing runs, and the line says why.
    not_run: []const u8,
};

const google_reason = "needs the owner's Google setup, which this CI does not have yet";
const ghcr_reason = "the GHCR push needs GitHub's own token; not ported";

/// The step of each id `changes.zig` selects, in `changes.demo_ids` order and then the packages
/// demo. An empty step is a demo that cannot run here (`not_run`).
const steps = [_][]const u8{
    "demo-m0",  "demo-m1", "demo-m2",  "demo-m2b", "demo-m3",      "demo-m4",
    "demo-m5",  "demo-m6", "demo-m6b", "",         "demo-m7",      "demo-m8",
    "demo-m8b", "demo-m9", "demo-m10", "demo-c4",  "demo-s2-lazy", "demo-m8-packages",
};

comptime {
    assert(steps.len == changes.selectable_count);
}

/// The plan for one id of `changes.demo_ids` or the packages id; null for an unknown id.
pub fn plan_for_id(id: []const u8) ?Plan {
    const index = changes.index_of(id) orelse return null;
    if (steps[index].len == 0) return .{ .not_run = google_reason };
    return .{ .run = steps[index .. index + 1] };
}

/// The step an id names, empty for demo-m6d.
pub fn step_for_index(index: usize) []const u8 {
    return steps[index];
}

const all_steps = [_][]const u8{
    "demo-m0", "demo-m1",  "demo-m2",  "demo-m2b",      "demo-m3",      "demo-m4",
    "demo-m5", "demo-m6",  "demo-m6b", "demo-m7",       "demo-m8",      "demo-m8b",
    "demo-m9", "demo-m10", "demo-c4",  "demo-s2-probe", "demo-s2-lazy", "demo-z7",
};
const m8_steps = [_][]const u8{ "demo-m8", "demo-m8-packages" };

/// What `vm/<name>` runs, the mapping of `.github/workflows/vm.yml`: `<demo>` is the part of
/// `name` before its first dash. Null when the name picks no demo.
pub fn plan_for_branch(name: []const u8) ?Plan {
    if (std.mem.eql(u8, name, "m8-push-ghcr")) return .{ .not_run = ghcr_reason };
    const demo = name[0 .. std.mem.indexOfScalar(u8, name, '-') orelse name.len];
    if (std.mem.eql(u8, demo, "all")) return .{ .run = &all_steps };
    if (std.mem.eql(u8, demo, "m8")) return .{ .run = &m8_steps };
    if (std.mem.eql(u8, demo, "m6d")) return .{ .not_run = google_reason };
    if (std.mem.eql(u8, demo, "s2")) return .{ .run = &.{"demo-s2-probe"} };
    if (std.mem.eql(u8, demo, "s2lazy")) return .{ .run = &.{"demo-s2-lazy"} };
    if (std.mem.eql(u8, demo, "m2bprobe")) return .{ .run = &.{"demo-m2b-probe"} };
    if (std.mem.eql(u8, demo, "z7")) return .{ .run = &.{"demo-z7"} };
    const plain = [_][]const u8{
        "m0", "m1", "m2", "m2b", "m3", "m4", "m5", "m6", "m6b", "m7", "m8b", "m9", "m10", "c4",
    };
    for (plain) |id| {
        if (!std.mem.eql(u8, demo, id)) continue;
        const found = changes.index_of(id) orelse unreachable; // Every plain id is a demo id.
        return .{ .run = steps[found .. found + 1] };
    }
    return null;
}

/// The demos that pull from Docker Hub reach it through mirror.gcr.io (Docker Hub's anonymous
/// limit is per address; docs/DECISIONS.md), as ci.yml set for them.
pub fn needs_mirror(step: []const u8) bool {
    const mirrored = [_][]const u8{
        "demo-m4", "demo-m5", "demo-m6", "demo-m6b", "demo-m7", "demo-m8", "demo-m8-packages",
        "demo-m9",
    };
    for (mirrored) |name| {
        if (std.mem.eql(u8, name, step)) return true;
    }
    return false;
}

test "demos: every selectable id has a step, and the step is a build step name" {
    // Goal: an id added to changes.zig without a step, or a mistyped step, fails here and not in
    // CI. Method: resolve each id; every non-empty step starts with demo- and is unique.
    var seen: usize = 0;
    for (changes.demo_ids ++ [_][]const u8{changes.packages_id}) |id| {
        const plan = plan_for_id(id).?;
        switch (plan) {
            .run => |list| {
                try std.testing.expectEqual(@as(usize, 1), list.len);
                try std.testing.expect(std.mem.startsWith(u8, list[0], "demo-"));
                seen += 1;
            },
            .not_run => try std.testing.expectEqualStrings("m6d", id),
        }
    }
    try std.testing.expectEqual(@as(usize, changes.selectable_count - 1), seen);
    try std.testing.expectEqual(@as(?Plan, null), plan_for_id("z7"));
}

test "demos: scratch branch names map as vm.yml does" {
    // Goal: vm/<demo>-<slug> picks the demos .github/workflows/vm.yml picked. Method: one name
    // per case of its `case`.
    const expect = std.testing.expectEqualStrings;
    try expect("demo-m4", plan_for_branch("m4-slice2").?.run[0]);
    try expect("demo-m6b", plan_for_branch("m6b-x").?.run[0]);
    try expect("demo-m2b", plan_for_branch("m2b").?.run[0]);
    try expect("demo-m2b-probe", plan_for_branch("m2bprobe-a-b").?.run[0]);
    try expect("demo-s2-probe", plan_for_branch("s2-1").?.run[0]);
    try expect("demo-s2-lazy", plan_for_branch("s2lazy-1").?.run[0]);
    try expect("demo-z7", plan_for_branch("z7-1").?.run[0]);
    try expect("demo-m8b", plan_for_branch("m8b-1").?.run[0]);
    const m8 = plan_for_branch("m8-1").?.run;
    try std.testing.expectEqual(@as(usize, 2), m8.len);
    try expect("demo-m8-packages", m8[1]);
    try std.testing.expectEqual(@as(usize, 18), plan_for_branch("all-x").?.run.len);
    try std.testing.expect(plan_for_branch("m6d-x").? == .not_run);
    try std.testing.expect(plan_for_branch("m8-push-ghcr").? == .not_run);
    try std.testing.expectEqual(@as(?Plan, null), plan_for_branch("m11-x"));
    try std.testing.expectEqual(@as(?Plan, null), plan_for_branch(""));
    try std.testing.expect(needs_mirror("demo-m9") and !needs_mirror("demo-m0"));
}
