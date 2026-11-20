//! Runs ops/backup/sync-test.sh, the test of the git backup's copy job (ops/backup/sync.sh) and of
//! the restore in ops/backup/README.md, against local bare repositories standing in for GitHub and
//! Forgejo. The script says what it covers. Run from the repository root, as `zig build test` does.

const std = @import("std");
const testing = std.testing;

const script = "ops/backup/sync-test.sh";

test "backup sync: copy, archive, clash, refusal, FAIL lines and restore" {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "bash", script },
    }) catch |err| switch (err) {
        // No bash here: the script cannot run, and the reason is this skip.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // The script exits 0 with a SKIP line only when git is missing; that is a skip, not a pass.
    if (std.mem.startsWith(u8, result.stdout, "sync-test: SKIP")) return error.SkipZigTest;
    const passed = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!passed) std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    try testing.expect(passed);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "sync-test: OK") != null);
}
