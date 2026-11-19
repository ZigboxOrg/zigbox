//! The one pattern language CI's tools share: `*` matches any run of characters, `/` included,
//! and every other character matches itself. It is bash's `case` pattern restricted to what
//! `.github/ci-changes.sh` used, so the path rules read as they did there. Build-host tooling.

const std = @import("std");
const assert = std.debug.assert;

/// True if `text` matches `pattern` as a whole. Linear in the product of the two lengths at
/// worst: the loop backtracks only to the last `*`, and each backtrack moves `mark` forward.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = t;
            p += 1;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |at| {
            assert(pattern[at] == '*');
            mark += 1;
            p = at + 1;
            t = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// True if `text` matches any of `patterns`.
pub fn matches_any(patterns: []const []const u8, text: []const u8) bool {
    for (patterns) |pattern| {
        if (matches(pattern, text)) return true;
    }
    return false;
}

test "glob: star crosses slashes, other characters match themselves" {
    // Goal: the bash `case` behaviour the path rules rely on, at its edges. Method: table.
    try std.testing.expect(matches("src/*", "src/a/b.zig"));
    try std.testing.expect(matches("src/*_tests.zig", "src/x/y_tests.zig"));
    try std.testing.expect(matches("*.md", "docs/a.md"));
    try std.testing.expect(matches("a*b*c", "aXbYbZc"));
    try std.testing.expect(matches("*", ""));
    try std.testing.expect(matches("", ""));
    try std.testing.expect(!matches("", "a"));
    try std.testing.expect(!matches("src/*", "src"));
    try std.testing.expect(!matches("src/*_tests.zig", "src/x/y_test.zig"));
    try std.testing.expect(!matches("a*b", "abc"));
    try std.testing.expect(matches_any(&.{ "x", "y*" }, "yes"));
    try std.testing.expect(!matches_any(&.{}, "yes"));
}
