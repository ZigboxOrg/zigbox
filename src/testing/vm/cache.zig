//! The VM demos' downloads, kept between runs on a box with a disk of its own (ops/ci/README.md).
//! GitHub's `actions/cache` did this for ci.yml; the self-hosted CI has no such action, so the
//! harness's driver (src/ci/demos.zig) calls `restore` before a demo and `save` after it.
//!
//! The same four entries, the same paths and the same keys as the workflow had: an entry is the
//! files of one pinned download, and its key is the entry's prefix and the first sixteen hex
//! digits of the SHA-256 of the file that pins it (a new pin is a new key, and an old key is never
//! read again; prune by hand). The rules:
//!
//!   - Opt-in: with no store directory nothing here runs, and a developer's machine is untouched.
//!   - `restore` copies, never links: demo-m4 writes into `m4-blobs.img`, which must not change
//!     the store.
//!   - `save` holds a lock on the store, so concurrent pipelines take turns; an entry is written
//!     under a temporary name and renamed, so it appears whole or not at all; and a key once
//!     stored is never overwritten (as `actions/cache`).
//!
//! Build-host tooling: it runs in the CI driver, never in `zbx`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const glob = @import("../../ci/glob.zig");

pub const Entry = struct {
    name: []const u8,
    /// The workspace directory the files live in, relative to the workspace.
    dir: []const u8,
    /// The files of the entry, as globs of names within `dir`.
    globs: []const []const u8,
    /// The file that pins the download, relative to the workspace; its hash is the key.
    pin: []const u8,
    key_prefix: []const u8,
};

pub const entries = [_]Entry{
    .{
        .name = "image",
        .dir = ".zig-cache/zbx-vm",
        .globs = &.{"ubuntu-24.04-server-cloudimg-amd64.img"},
        .pin = "src/testing/vm/lib/image.zon",
        .key_prefix = "vm-image",
    },
    .{
        .name = "guests",
        .dir = ".zig-cache/zbx-vm-guests",
        .globs = &.{ "debian-*.qcow2", "Fedora-*.qcow2", "Rocky-*.qcow2" },
        .pin = "src/testing/vm/lib/guests.zon",
        .key_prefix = "vm-guests",
    },
    .{
        .name = "alpine",
        .dir = ".zig-cache/zbx-vm",
        .globs = &.{"alpine-*.tar.gz"},
        .pin = "src/testing/vm/alpine.zon",
        .key_prefix = "vm-alpine",
    },
    .{
        .name = "blobs",
        .dir = ".zig-cache/zbx-vm",
        .globs = &.{"m4-blobs.img"},
        .pin = "src/testing/vm/zbx.lock",
        .key_prefix = "vm-m4-blobs",
    },
};

const key_digest_bytes = 8;
const key_bytes_max = 64;
const pin_bytes_max = 1 << 20;

/// Where the entries live: the workspace the demos run in, and the store shared by pipelines.
pub const Cache = struct {
    io: Io,
    workspace: Io.Dir,
    store: Io.Dir,
    log: *Io.Writer,
};

/// The key of `entry`: its prefix, a dash and the hash of its pin file (16 hex digits). Null when
/// the pin cannot be read (a checkout without it has nothing to cache by).
fn key_of(cache: *const Cache, entry: *const Entry, buffer: *[key_bytes_max]u8) ?[]const u8 {
    var pin_buffer: [pin_bytes_max]u8 = undefined;
    const pin = cache.workspace.readFile(cache.io, entry.pin, &pin_buffer) catch return null;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pin, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..key_digest_bytes].*, .lower);
    // The buffer holds the longest prefix and 16 digits.
    return std.fmt.bufPrint(buffer, "{s}-{s}", .{ entry.key_prefix, hex }) catch unreachable;
}

/// Copies each entry the store has into the workspace. A miss, or an entry that cannot be
/// copied, is a line and not a failure: the demo downloads what is missing.
pub fn restore(cache: *const Cache, which: []const Entry) void {
    for (which) |*entry| {
        var buffer: [key_bytes_max]u8 = undefined;
        const key = key_of(cache, entry, &buffer) orelse continue;
        restore_one(cache, entry, key) catch |err| {
            const name = @errorName(err);
            cache.log.print("cache: {s}: miss ({s}: {s})\n", .{ entry.name, key, name }) catch {};
            continue;
        };
        cache.log.print("cache: {s}: hit ({s})\n", .{ entry.name, key }) catch {};
    }
}

fn restore_one(cache: *const Cache, entry: *const Entry, key: []const u8) !void {
    const io = cache.io;
    var source = try cache.store.openDir(io, key, .{ .iterate = true });
    defer source.close(io);
    try cache.workspace.createDirPath(io, entry.dir);
    var target = try cache.workspace.openDir(io, entry.dir, .{});
    defer target.close(io);
    var it = source.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .file) continue;
        try source.copyFile(file.name, target, file.name, io, .{});
    }
}

/// Stores each entry the store lacks, from the workspace; takes the store's lock for the whole
/// pass. Failures are lines: a cache that cannot be written never fails a demo.
pub fn save(cache: *const Cache, which: []const Entry) void {
    const io = cache.io;
    const lock_options: Io.Dir.CreateFileOptions = .{ .truncate = false, .lock = .exclusive };
    const lock = cache.store.createFile(io, ".lock", lock_options) catch |err| {
        cache.log.print("cache: not saving: no lock ({s})\n", .{@errorName(err)}) catch {};
        return;
    };
    defer lock.close(io);
    for (which) |*entry| {
        var buffer: [key_bytes_max]u8 = undefined;
        const key = key_of(cache, entry, &buffer) orelse continue;
        const saved = save_one(cache, entry, key) catch |err| {
            const why = @errorName(err);
            cache.log.print("cache: {s}: not saved ({s})\n", .{ entry.name, why }) catch {};
            continue;
        };
        if (saved) cache.log.print("cache: {s}: saved ({s})\n", .{ entry.name, key }) catch {};
    }
}

/// True if it stored the entry; false if the key exists or the workspace has no file for it.
fn save_one(cache: *const Cache, entry: *const Entry, key: []const u8) !bool {
    const io = cache.io;
    if (cache.store.access(io, key, .{})) |_| return false else |_| {}
    var source = cache.workspace.openDir(io, entry.dir, .{ .iterate = true }) catch return false;
    defer source.close(io);
    var random: [8]u8 = undefined;
    io.random(&random);
    var temp_buffer: [key_bytes_max + 32]u8 = undefined;
    const suffix = std.mem.readInt(u64, &random, .little);
    const temp = try std.fmt.bufPrint(&temp_buffer, ".{s}.tmp.{x}", .{ key, suffix });
    try cache.store.createDirPath(io, temp);
    errdefer cache.store.deleteTree(io, temp) catch {};
    const found = try copy_matching(cache, entry, source, temp);
    if (found == 0) {
        try cache.store.deleteTree(io, temp);
        return false;
    }
    // The key was absent when the lock was taken, and the lock is ours: nothing else renames it.
    try cache.store.rename(temp, cache.store, key, io);
    return true;
}

/// Copies the non-empty files of `source` that match the entry's globs into the store's `temp`
/// directory; returns how many.
fn copy_matching(cache: *const Cache, entry: *const Entry, source: Io.Dir, temp: []const u8) !u32 {
    const io = cache.io;
    var target = try cache.store.openDir(io, temp, .{});
    defer target.close(io);
    var found: u32 = 0;
    var it = source.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .file) continue;
        if (!glob.matches_any(entry.globs, file.name)) continue;
        const stat = try source.statFile(io, file.name, .{});
        if (stat.size == 0) continue;
        try source.copyFile(file.name, target, file.name, io, .{});
        found += 1;
    }
    return found;
}

const testing = std.testing;

fn test_entries() [1]Entry {
    return .{.{
        .name = "t",
        .dir = "w/dl",
        .globs = &.{ "a-*.img", "b.bin" },
        .pin = "pin.zon",
        .key_prefix = "vm-t",
    }};
}

test "vm cache: a key is the prefix and sixteen digits of the pin's hash" {
    // Goal: the keys the workflow's actions/cache used (`sha256sum | cut -c1-16`), so an old
    // store stays valid. Method: hash a known pin and compare with the digest of "abc".
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pin.zon", .data = "abc" });
    var sink: [64]u8 = undefined;
    var log: Io.Writer = .fixed(&sink);
    const cache: Cache = .{ .io = testing.io, .workspace = tmp.dir, .store = tmp.dir, .log = &log };
    const which = test_entries();
    var buffer: [key_bytes_max]u8 = undefined;
    const key = key_of(&cache, &which[0], &buffer).?;
    try testing.expectEqualStrings("vm-t-ba7816bf8f01cfea", key);
    try testing.expectEqual(@as(?[]const u8, null), key_of(&cache, &.{
        .name = "x",
        .dir = "d",
        .globs = &.{},
        .pin = "missing.zon",
        .key_prefix = "p",
    }, &buffer));
}

test "vm cache: save stores once, restore copies, nothing is overwritten" {
    // Goal: the rules in the header. Method: save from a workspace, change the workspace, save
    // again (the stored entry must keep the first bytes), restore into a fresh workspace and edit
    // the copy (the store must not change: a copy, not a link).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "w/dl");
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/pin.zon", .data = "abc" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/dl/a-1.img", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/dl/b.bin", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/dl/other.txt", .data = "no" });
    var workspace = try tmp.dir.openDir(io, "w", .{});
    defer workspace.close(io);
    var store = try tmp.dir.openDir(io, "store", .{ .iterate = true });
    defer store.close(io);
    var sink: [1024]u8 = undefined;
    var log: Io.Writer = .fixed(&sink);
    const cache: Cache = .{ .io = io, .workspace = workspace, .store = store, .log = &log };
    var which = test_entries();
    which[0].dir = "dl";
    save(&cache, &which);
    try workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "second" });
    save(&cache, &which);
    const key = "vm-t-ba7816bf8f01cfea";
    var data: [16]u8 = undefined;
    try testing.expectEqualStrings("first", try store.readFile(io, key ++ "/a-1.img", &data));
    // Empty and unmatched files are not stored, and no temporary directory is left.
    try testing.expectError(error.FileNotFound, store.access(io, key ++ "/b.bin", .{}));
    try testing.expectError(error.FileNotFound, store.access(io, key ++ "/other.txt", .{}));
    var count: u32 = 0;
    var it = store.iterate();
    while (try it.next(io)) |item| {
        if (std.mem.startsWith(u8, item.name, ".vm-")) return error.TemporaryLeft;
        count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count); // The entry and the lock file.
    // Restore into a fresh workspace, then change the copy.
    try tmp.dir.createDirPath(io, "w2");
    try tmp.dir.writeFile(io, .{ .sub_path = "w2/pin.zon", .data = "abc" });
    var fresh = try tmp.dir.openDir(io, "w2", .{});
    defer fresh.close(io);
    const again: Cache = .{ .io = io, .workspace = fresh, .store = store, .log = &log };
    restore(&again, &which);
    try testing.expectEqualStrings("first", try fresh.readFile(io, "dl/a-1.img", &data));
    try fresh.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "edited" });
    try testing.expectEqualStrings("first", try store.readFile(io, key ++ "/a-1.img", &data));
    // A pin that changes is a miss, not a stale hit.
    try fresh.writeFile(io, .{ .sub_path = "pin.zon", .data = "abd" });
    try fresh.deleteTree(io, "dl");
    restore(&again, &which);
    try testing.expectError(error.FileNotFound, fresh.access(io, "dl/a-1.img", .{}));
}
