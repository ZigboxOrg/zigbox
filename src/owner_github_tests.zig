//! Runs ops/ci/owner-github-test.sh, the test of ops/ci/owner-github.sh (the owner's GitHub side of
//! the CI box's accounts) against a stub `gh` that answers as GitHub does. The script says what it
//! covers. Run from the repository root, as `zig build test` does.

const std = @import("std");
const testing = std.testing;

const script = "ops/ci/owner-github-test.sh";

test "owner-github: membership, teams, 404 and 502, owner, member settings, merging" {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "bash", script },
    }) catch |err| switch (err) {
        // No bash here: the script cannot run, and the reason is this skip.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // The script exits 0 with a SKIP line only when jq is missing; that is a skip, not a pass.
    if (std.mem.startsWith(u8, result.stdout, "owner-github-test: SKIP")) return error.SkipZigTest;
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed) std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    try testing.expect(passed);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "owner-github-test: OK") != null);
}
