//! The VM demos' downloads, kept between runs on a box with a disk of its own (ops/ci/README.md).
//! GitHub's `actions/cache` did this for ci.yml; the self-hosted CI has no such action, so the
//! harness's driver (src/ci/demos.zig) calls `restore` before a demo and `save` after it.
//!
//! The same four entries, the same paths and the same keys as the workflow had: an entry is the
//! files of one pinned download, and its key is the entry's prefix and the first sixteen hex
//! digits of the SHA-256 of the file that pins it (a new pin is a new key). The rules:
//!
//!   - Opt-in: with no store directory nothing here runs, and a developer's machine is untouched.
//!   - `restore` copies, never links: demo-m4 writes into `m4-blobs.img`, which must not change
//!     the store.
//!   - `save` holds a lock on the store, so concurrent pipelines take turns; an entry is written
//!     under a temporary name and renamed, so it appears whole or not at all; and a key once
//!     stored is never overwritten (as `actions/cache`).
//!   - Each stored entry carries the SHA-256 of every file (`.sha256`, written when it is saved),
//!     and `restore` checks each copy against it: a file that does not match is deleted from the
//!     workspace and the whole entry from the store, so the demo downloads afresh and the next
//!     `save` stores a good copy. An entry without the list is a miss.
//!   - `save` prunes: of each entry's keys it keeps the current one and the newest of the others,
//!     `keys_per_entry_max` in all, so a pin that moves never leaves more than one old copy.
//!
//! The hashes catch corruption and truncation, not tampering: the list is written by whoever
//! writes the entry, so a pipeline that rewrites both passes the check. What keeps `main` clean is
//! the scopes: the pipelines of pull requests and of `main` mount different store directories
//! (.woodpecker/*.yaml), so nothing a pull request saves is ever restored on `main`.
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

/// The list of the entry's files and their SHA-256, inside each stored entry.
const sums_name = ".sha256";
/// One line of the list: 64 hex digits, two spaces, a file name, a newline.
const sums_bytes_max = 4096;
const file_name_bytes_max = 255;
/// Files per entry: the globs match a handful (one image, three guests).
const files_per_entry_max = 16;
/// Stored keys of one entry kept by `save`: the current one and one older.
pub const keys_per_entry_max = 2;
/// Directories in the store `prune` looks at before it stops (a bound on the walk).
const store_items_max = 256;
const hash_chunk_bytes = 64 * 1024;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

comptime {
    assert(keys_per_entry_max >= 1);
    // A list of the entries' real files (short names) fits: four lines of 64 + 2 + 64 + 1 bytes.
    assert(sums_bytes_max >= 4 * (2 * Sha256.digest_length + 2 + 64 + 1));
}

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
            // An entry that fails its check, or has no usable list (one saved before lists
            // existed), is dropped so that the next save stores a checked copy.
            if (is_bad_entry(err)) drop_entry(cache, key);
            continue;
        };
        cache.log.print("cache: {s}: hit ({s})\n", .{ entry.name, key }) catch {};
    }
}

fn is_bad_entry(err: anyerror) bool {
    return switch (err) {
        error.HashMismatch, error.NoHashList, error.BadHashList, error.HashListTooLong => true,
        else => false,
    };
}

/// Copies the files the entry's list names and checks each copy's SHA-256 against it. A copy
/// that does not match is deleted from the workspace (`error.HashMismatch`).
fn restore_one(cache: *const Cache, entry: *const Entry, key: []const u8) !void {
    const io = cache.io;
    var source = try cache.store.openDir(io, key, .{});
    defer source.close(io);
    var sums_buffer: [sums_bytes_max]u8 = undefined;
    const sums = source.readFile(io, sums_name, &sums_buffer) catch |err| switch (err) {
        error.FileNotFound => return error.NoHashList,
        else => return err,
    };
    try cache.workspace.createDirPath(io, entry.dir);
    var target = try cache.workspace.openDir(io, entry.dir, .{});
    defer target.close(io);
    var lines = std.mem.tokenizeScalar(u8, sums, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        const sum = try parse_sum_line(line);
        count += 1;
        if (count > files_per_entry_max) return error.HashListTooLong;
        try source.copyFile(sum.name, target, sum.name, io, .{});
        const digest = try hash_file(io, target, sum.name);
        if (!std.mem.eql(u8, &digest, &sum.digest)) {
            target.deleteFile(io, sum.name) catch {};
            return error.HashMismatch;
        }
    }
    if (count == 0) return error.NoHashList;
}

/// Deletes a stored entry that failed its check, under the store's lock.
fn drop_entry(cache: *const Cache, key: []const u8) void {
    const io = cache.io;
    const lock_options: Io.Dir.CreateFileOptions = .{ .truncate = false, .lock = .exclusive };
    const lock = cache.store.createFile(io, ".lock", lock_options) catch return;
    defer lock.close(io);
    cache.store.deleteTree(io, key) catch {};
}

const SumLine = struct { digest: Digest, name: []const u8 };

/// Parses `<64 hex>  <name>`; the name must be a plain file name.
fn parse_sum_line(line: []const u8) !SumLine {
    const hex_len = 2 * @as(usize, Sha256.digest_length);
    if (line.len <= hex_len + 2) return error.BadHashList;
    if (!std.mem.eql(u8, line[hex_len .. hex_len + 2], "  ")) return error.BadHashList;
    const name = line[hex_len + 2 ..];
    if (name.len > file_name_bytes_max) return error.BadHashList;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.BadHashList;
    if (name[0] == '.') return error.BadHashList;
    var result: SumLine = .{ .digest = undefined, .name = name };
    _ = std.fmt.hexToBytes(&result.digest, line[0..hex_len]) catch return error.BadHashList;
    assert(result.name.len > 0);
    return result;
}

/// The SHA-256 of `name` in `dir`, read in fixed chunks.
fn hash_file(io: Io, dir: Io.Dir, name: []const u8) !Digest {
    assert(name.len > 0);
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buffer: [hash_chunk_bytes]u8 = undefined;
    var reader = file.reader(io, &.{});
    var hasher: Sha256 = .init(.{});
    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        if (n < buffer.len) break;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
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
        prune(cache, entry, key);
    }
}

/// Deletes the entry's stored keys beyond `keys_per_entry_max`: the current key stays, then the
/// newest others by the time their hash list was written. The caller holds the store's lock.
fn prune(cache: *const Cache, entry: *const Entry, current: []const u8) void {
    const io = cache.io;
    var store = cache.store.openDir(io, ".", .{ .iterate = true }) catch return;
    defer store.close(io);
    var names: [store_items_max][key_bytes_max]u8 = undefined;
    var lengths: [store_items_max]u8 = undefined;
    var times: [store_items_max]i96 = undefined;
    var count: u32 = 0;
    var it = store.iterate();
    while (it.next(io) catch null) |item| {
        if (count == store_items_max) break;
        if (item.kind != .directory) continue;
        if (!is_key_of(entry, item.name)) continue;
        if (std.mem.eql(u8, item.name, current)) continue;
        @memcpy(names[count][0..item.name.len], item.name);
        lengths[count] = @intCast(item.name.len);
        times[count] = saved_time(cache, item.name);
        count += 1;
    }
    // Keep the newest `keys_per_entry_max - 1` others: delete the oldest until that many remain.
    while (count > keys_per_entry_max - 1) {
        var oldest: u32 = 0;
        for (1..count) |index| {
            if (times[index] < times[oldest]) oldest = @intCast(index);
        }
        const name = names[oldest][0..lengths[oldest]];
        cache.store.deleteTree(io, name) catch {};
        cache.log.print("cache: {s}: pruned ({s})\n", .{ entry.name, name }) catch {};
        count -= 1;
        names[oldest] = names[count];
        lengths[oldest] = lengths[count];
        times[oldest] = times[count];
    }
}

/// True if `name` is one of the entry's keys: its prefix, a dash, sixteen hex digits.
fn is_key_of(entry: *const Entry, name: []const u8) bool {
    const digits = 2 * key_digest_bytes;
    if (name.len != entry.key_prefix.len + 1 + digits) return false;
    if (!std.mem.startsWith(u8, name, entry.key_prefix)) return false;
    if (name[entry.key_prefix.len] != '-') return false;
    for (name[entry.key_prefix.len + 1 ..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// When the stored key was saved (its hash list's mtime); 0, the oldest, if it has none.
fn saved_time(cache: *const Cache, key: []const u8) i96 {
    var buffer: [key_bytes_max + sums_name.len + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ key, sums_name }) catch return 0;
    const stat = cache.store.statFile(cache.io, path, .{}) catch return 0;
    return stat.mtime.nanoseconds;
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
    try write_sums(cache, temp);
    // The key was absent when the lock was taken, and the lock is ours: nothing else renames it.
    try cache.store.rename(temp, cache.store, key, io);
    return true;
}

/// Writes the hash list of the files in the store's `temp` directory, hashed from those copies.
fn write_sums(cache: *const Cache, temp: []const u8) !void {
    const io = cache.io;
    var dir = try cache.store.openDir(io, temp, .{ .iterate = true });
    defer dir.close(io);
    var buffer: [sums_bytes_max]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var count: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (file.kind != .file) continue;
        // Only names `parse_sum_line` takes back.
        if (file.name.len > file_name_bytes_max) return error.NameTooLong;
        if (file.name[0] == '.') return error.BadFileName;
        if (std.mem.indexOfScalar(u8, file.name, '\n') != null) return error.BadFileName;
        count += 1;
        if (count > files_per_entry_max) return error.TooManyFiles;
        const digest = try hash_file(io, dir, file.name);
        try writer.print("{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), file.name });
    }
    assert(count > 0);
    try dir.writeFile(io, .{ .sub_path = sums_name, .data = writer.buffered() });
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

test "vm cache: a stored file that fails its hash is not restored, and the entry is dropped" {
    // Goal: a corrupted or truncated store never reaches a demo (m4-blobs.img is a disk image the
    // guest boots). Method: save, change the stored copy, restore into a fresh workspace: the
    // copy must be gone and the stored entry too; an entry with no hash list must be a miss.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "w/dl");
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.createDirPath(io, "w2");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/pin.zon", .data = "abc" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w2/pin.zon", .data = "abc" });
    try tmp.dir.writeFile(io, .{ .sub_path = "w/dl/a-1.img", .data = "good" });
    var workspace = try tmp.dir.openDir(io, "w", .{});
    defer workspace.close(io);
    var fresh = try tmp.dir.openDir(io, "w2", .{});
    defer fresh.close(io);
    var store = try tmp.dir.openDir(io, "store", .{});
    defer store.close(io);
    var sink: [1024]u8 = undefined;
    var log: Io.Writer = .fixed(&sink);
    const cache: Cache = .{ .io = io, .workspace = workspace, .store = store, .log = &log };
    const again: Cache = .{ .io = io, .workspace = fresh, .store = store, .log = &log };
    var which = test_entries();
    which[0].dir = "dl";
    const key = "vm-t-ba7816bf8f01cfea";
    save(&cache, &which);
    try store.access(io, key ++ "/" ++ sums_name, .{});
    try store.writeFile(io, .{ .sub_path = key ++ "/a-1.img", .data = "evil" });
    restore(&again, &which);
    try testing.expectError(error.FileNotFound, fresh.access(io, "dl/a-1.img", .{}));
    try testing.expectError(error.FileNotFound, store.access(io, key, .{}));
    // Saved again, then stripped of its list (as one saved before lists existed): a miss, not an
    // unchecked hit, and dropped so that the next save replaces it.
    save(&cache, &which);
    try store.deleteFile(io, key ++ "/" ++ sums_name);
    restore(&again, &which);
    try testing.expectError(error.FileNotFound, fresh.access(io, "dl/a-1.img", .{}));
    try testing.expectError(error.FileNotFound, store.access(io, key, .{}));
    // A good entry restores.
    save(&cache, &which);
    restore(&again, &which);
    var data: [16]u8 = undefined;
    try testing.expectEqualStrings("good", try fresh.readFile(io, "dl/a-1.img", &data));
}

test "vm cache: save keeps at most keys_per_entry_max keys of an entry" {
    // Goal: a store that never grows past a bound as pins move. Method: save under four pins in
    // turn; the store must then hold the last two keys and nothing older.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "w/dl");
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/dl/a-1.img", .data = "image" });
    var workspace = try tmp.dir.openDir(io, "w", .{});
    defer workspace.close(io);
    var store = try tmp.dir.openDir(io, "store", .{ .iterate = true });
    defer store.close(io);
    var sink: [4096]u8 = undefined;
    var log: Io.Writer = .fixed(&sink);
    const cache: Cache = .{ .io = io, .workspace = workspace, .store = store, .log = &log };
    var which = test_entries();
    which[0].dir = "dl";
    const pins = [_][]const u8{ "pin 1", "pin 2", "pin 3", "pin 4" };
    var keys: [pins.len][key_bytes_max]u8 = undefined;
    for (pins, 0..) |pin, index| {
        try workspace.writeFile(io, .{ .sub_path = "pin.zon", .data = pin });
        _ = key_of(&cache, &which[0], &keys[index]).?;
        save(&cache, &which);
    }
    const key_len = which[0].key_prefix.len + 1 + 2 * key_digest_bytes;
    var count: u32 = 0;
    var it = store.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .directory) continue;
        count += 1;
    }
    try testing.expectEqual(@as(u32, keys_per_entry_max), count);
    try store.access(io, keys[3][0..key_len], .{});
    try store.access(io, keys[2][0..key_len], .{});
    try testing.expectError(error.FileNotFound, store.access(io, keys[0][0..key_len], .{}));
}
