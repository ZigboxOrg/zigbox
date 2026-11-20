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
//!     stored is not overwritten (as `actions/cache`), with two exceptions below.
//!   - An entry is replaced, never edited, when what is stored is no use: its hash list is
//!     missing or unreadable (always), or, for an entry the demo writes into (`grows`, the m4
//!     blob image), the workspace's files differ from the stored ones by hash and the demo steps
//!     all passed (`SaveOptions.replace_changed`). Without that, a cold copy saved by the first
//!     run, before the demo had pulled anything, would stay for good and every later run would
//!     pull again. The new copy is written under a temporary name, the old one is renamed aside,
//!     the new one renamed to the key and the old one deleted, all under the store's lock; a
//!     restore, which takes no lock, meets the old copy or the new one, or a miss for the instant
//!     between the renames, and every copy it takes is checked against its own list.
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
    /// The demo writes into these files (the m4 blob image keeps what the guest pulled), so a
    /// stored copy goes stale as the workspace's grows.
    grows: bool = false,
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
        .grows = true,
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
/// A temporary or set-aside name: a dot, a key, a suffix and 16 hex digits.
const scratch_bytes_max = key_bytes_max + 32;
/// Leftover scratch directories one `save` removes (a crash leaves at most a few).
const leftovers_max = 16;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

comptime {
    assert(keys_per_entry_max >= 1);
    // A list of the entries' real files (short names) fits: four lines of 64 + 2 + 64 + 1 bytes.
    assert(sums_bytes_max >= 4 * (2 * Sha256.digest_length + 2 + 64 + 1));
}

pub const SaveOptions = struct {
    /// True when the demo steps all passed: only then is a stored `grows` entry replaced by a
    /// workspace that differs (a failed run may leave a half-written image).
    replace_changed: bool,
};

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

/// Stores each entry the store lacks, or holds in a form that is no use (see the header), from
/// the workspace; takes the store's lock for the whole pass. Failures are lines: a cache that
/// cannot be written never fails a demo.
pub fn save(cache: *const Cache, which: []const Entry, options: SaveOptions) void {
    const io = cache.io;
    const lock_options: Io.Dir.CreateFileOptions = .{ .truncate = false, .lock = .exclusive };
    const lock = cache.store.createFile(io, ".lock", lock_options) catch |err| {
        cache.log.print("cache: not saving: no lock ({s})\n", .{@errorName(err)}) catch {};
        return;
    };
    defer lock.close(io);
    sweep_leftovers(cache);
    for (which) |*entry| {
        var buffer: [key_bytes_max]u8 = undefined;
        const key = key_of(cache, entry, &buffer) orelse continue;
        const saved = save_one(cache, entry, key, options) catch |err| {
            const why = @errorName(err);
            cache.log.print("cache: {s}: not saved ({s})\n", .{ entry.name, why }) catch {};
            continue;
        };
        switch (saved) {
            .kept => {},
            .stored => cache.log.print("cache: {s}: saved ({s})\n", .{ entry.name, key }) catch {},
            .replaced => {
                cache.log.print("cache: {s}: replaced ({s})\n", .{ entry.name, key }) catch {};
            },
        }
        prune(cache, entry, key);
    }
}

/// Deletes the scratch directories (temporary and set-aside, named with a leading dot) that a
/// `save` killed half way left. The caller holds the store's lock, so none is in use.
fn sweep_leftovers(cache: *const Cache) void {
    const io = cache.io;
    var store = cache.store.openDir(io, ".", .{ .iterate = true }) catch return;
    defer store.close(io);
    var names: [leftovers_max][scratch_bytes_max]u8 = undefined;
    var lengths: [leftovers_max]u8 = undefined;
    var count: u32 = 0;
    var it = store.iterate();
    while (it.next(io) catch null) |item| {
        if (count == leftovers_max) break;
        if (item.kind != .directory) continue;
        if (item.name[0] != '.') continue;
        if (item.name.len > scratch_bytes_max) continue;
        @memcpy(names[count][0..item.name.len], item.name);
        lengths[count] = @intCast(item.name.len);
        count += 1;
    }
    for (0..count) |index| {
        const name = names[index][0..lengths[index]];
        cache.store.deleteTree(io, name) catch continue;
        cache.log.print("cache: removed a leftover ({s})\n", .{name}) catch {};
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

const Saved = enum { kept, stored, replaced };

/// Stores the entry (`.stored`), or replaces the stored one that is no use (`.replaced`), or
/// leaves things as they are (`.kept`: the key exists and is good, or the workspace has no file).
fn save_one(
    cache: *const Cache,
    entry: *const Entry,
    key: []const u8,
    options: SaveOptions,
) !Saved {
    const io = cache.io;
    const present = if (cache.store.access(io, key, .{})) |_| true else |_| false;
    if (present) {
        if (!stored_is_stale(cache, entry, key, options)) return .kept;
    }
    var source = cache.workspace.openDir(io, entry.dir, .{ .iterate = true }) catch return .kept;
    defer source.close(io);
    var temp_buffer: [scratch_bytes_max]u8 = undefined;
    const temp = scratch_name(io, &temp_buffer, key, "tmp");
    try cache.store.createDirPath(io, temp);
    errdefer cache.store.deleteTree(io, temp) catch {};
    const found = try copy_matching(cache, entry, source, temp);
    if (found == 0) {
        try cache.store.deleteTree(io, temp);
        return .kept;
    }
    try write_sums(cache, temp);
    if (!present) {
        // The key was absent when the lock was taken, and the lock is ours: nobody renames it.
        try cache.store.rename(temp, cache.store, key, io);
        return .stored;
    }
    try replace_key(cache, temp, key);
    return .replaced;
}

/// `.<key>.<kind>.<16 hex digits>`: a name no other save uses, and no key (it starts with a dot).
fn scratch_name(
    io: Io,
    buffer: *[scratch_bytes_max]u8,
    key: []const u8,
    kind: []const u8,
) []const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    const suffix = std.mem.readInt(u64, &random, .little);
    assert(kind.len <= 4);
    const format = ".{s}.{s}.{x:0>16}";
    // The buffer holds the longest key, a kind of at most four letters and 16 digits.
    return std.fmt.bufPrint(buffer, format, .{ key, kind, suffix }) catch unreachable;
}

/// Puts the finished `temp` directory at `key`, which exists: a directory cannot be renamed over
/// another, so the old one goes aside first, and comes back if the second rename fails. The
/// caller holds the store's lock.
fn replace_key(cache: *const Cache, temp: []const u8, key: []const u8) !void {
    const io = cache.io;
    var aside_buffer: [scratch_bytes_max]u8 = undefined;
    const aside = scratch_name(io, &aside_buffer, key, "old");
    try cache.store.rename(key, cache.store, aside, io);
    cache.store.rename(temp, cache.store, key, io) catch |err| {
        cache.store.rename(aside, cache.store, key, io) catch {};
        return err;
    };
    cache.store.deleteTree(io, aside) catch {};
}

/// True if the stored `key` should be replaced by the workspace's files: its hash list is missing
/// or unreadable, or the entry grows, the demo steps passed and the workspace's files differ.
fn stored_is_stale(
    cache: *const Cache,
    entry: *const Entry,
    key: []const u8,
    options: SaveOptions,
) bool {
    const io = cache.io;
    var source = cache.store.openDir(io, key, .{}) catch return true;
    defer source.close(io);
    var sums_buffer: [sums_bytes_max]u8 = undefined;
    const sums = source.readFile(io, sums_name, &sums_buffer) catch return true;
    if (!list_is_usable(sums)) return true;
    if (!entry.grows) return false;
    if (!options.replace_changed) return false;
    return !workspace_matches(cache, entry, sums);
}

fn list_is_usable(sums: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, sums, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        _ = parse_sum_line(line) catch return false;
        count += 1;
        if (count > files_per_entry_max) return false;
    }
    return count > 0;
}

/// True if the workspace holds exactly the files the list names, with the listed hashes. Any
/// error reading the workspace is "no": the entry is then rebuilt from what is there.
fn workspace_matches(cache: *const Cache, entry: *const Entry, sums: []const u8) bool {
    const io = cache.io;
    var source = cache.workspace.openDir(io, entry.dir, .{ .iterate = true }) catch return false;
    defer source.close(io);
    var present: u32 = 0;
    var it = source.iterate();
    while (it.next(io) catch return false) |file| {
        if (file.kind != .file) continue;
        if (!glob.matches_any(entry.globs, file.name)) continue;
        const stat = source.statFile(io, file.name, .{}) catch return false;
        if (stat.size == 0) continue;
        present += 1;
    }
    var listed: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        const sum = parse_sum_line(line) catch return false;
        listed += 1;
        const digest = hash_file(io, source, sum.name) catch return false;
        if (!std.mem.eql(u8, &digest, &sum.digest)) return false;
    }
    return present == listed;
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
    save(&cache, &which, .{ .replace_changed = true });
    try workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "second" });
    save(&cache, &which, .{ .replace_changed = true });
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
    save(&cache, &which, .{ .replace_changed = true });
    try store.access(io, key ++ "/" ++ sums_name, .{});
    try store.writeFile(io, .{ .sub_path = key ++ "/a-1.img", .data = "evil" });
    restore(&again, &which);
    try testing.expectError(error.FileNotFound, fresh.access(io, "dl/a-1.img", .{}));
    try testing.expectError(error.FileNotFound, store.access(io, key, .{}));
    // Saved again, then stripped of its list (as one saved before lists existed): a miss, not an
    // unchecked hit, and dropped so that the next save replaces it.
    save(&cache, &which, .{ .replace_changed = true });
    try store.deleteFile(io, key ++ "/" ++ sums_name);
    restore(&again, &which);
    try testing.expectError(error.FileNotFound, fresh.access(io, "dl/a-1.img", .{}));
    try testing.expectError(error.FileNotFound, store.access(io, key, .{}));
    // A good entry restores.
    save(&cache, &which, .{ .replace_changed = true });
    restore(&again, &which);
    var data: [16]u8 = undefined;
    try testing.expectEqualStrings("good", try fresh.readFile(io, "dl/a-1.img", &data));
}

test "vm cache: save keeps at most keys_per_entry_max keys of an entry" {
    // Goal: a store that never grows past a bound as pins move. Method: save under four pins in
    // turn; the store must then hold the last two keys and nothing older. Each save's hash list is
    // dated a second after the last: saves this close share an mtime on a coarse clock (the CI box
    // ties them), and a tie would keep an arbitrary key rather than the newer one.
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
    const key_len = which[0].key_prefix.len + 1 + 2 * key_digest_bytes;
    var path: [key_bytes_max + sums_name.len + 1]u8 = undefined;
    for (pins, 0..) |pin, index| {
        try workspace.writeFile(io, .{ .sub_path = "pin.zon", .data = pin });
        _ = key_of(&cache, &which[0], &keys[index]).?;
        save(&cache, &which, .{ .replace_changed = true });
        const key = keys[index][0..key_len];
        const sums = try std.fmt.bufPrint(&path, "{s}/{s}", .{ key, sums_name });
        const second: i96 = std.time.ns_per_s * @as(i96, @intCast(index + 1));
        const dated: Io.Timestamp = .fromNanoseconds(second);
        try store.setTimestamps(io, sums, .{ .modify_timestamp = .{ .new = dated } });
    }
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

/// A workspace and a store in a temporary directory, with one growing entry whose file is
/// `dl/a-1.img`; the tests below share it.
const Rig = struct {
    tmp: testing.TmpDir,
    workspace: Io.Dir,
    store: Io.Dir,
    sink: [4096]u8 = undefined,
    log: Io.Writer = undefined,

    fn open(rig: *Rig) !void {
        const io = testing.io;
        rig.tmp = testing.tmpDir(.{});
        try rig.tmp.dir.createDirPath(io, "w/dl");
        try rig.tmp.dir.createDirPath(io, "store");
        try rig.tmp.dir.writeFile(io, .{ .sub_path = "w/pin.zon", .data = "abc" });
        rig.workspace = try rig.tmp.dir.openDir(io, "w", .{});
        rig.store = try rig.tmp.dir.openDir(io, "store", .{ .iterate = true });
        rig.log = .fixed(&rig.sink);
    }

    fn close(rig: *Rig) void {
        rig.workspace.close(testing.io);
        rig.store.close(testing.io);
        rig.tmp.cleanup();
    }

    fn cache(rig: *Rig) Cache {
        return .{
            .io = testing.io,
            .workspace = rig.workspace,
            .store = rig.store,
            .log = &rig.log,
        };
    }
};

const test_key = "vm-t-ba7816bf8f01cfea";

fn growing_entries() [1]Entry {
    var which = test_entries();
    which[0].dir = "dl";
    which[0].grows = true;
    return which;
}

fn expect_stored(store: Io.Dir, expected: []const u8) !void {
    var data: [16]u8 = undefined;
    const stored = try store.readFile(testing.io, test_key ++ "/a-1.img", &data);
    try testing.expectEqualStrings(expected, stored);
}

fn expect_no_scratch(store: Io.Dir) !void {
    var it = store.iterate();
    while (try it.next(testing.io)) |item| {
        if (item.kind == .directory) try testing.expect(item.name[0] != '.');
    }
}

test "vm cache: a growing entry is replaced when the workspace's copy differs" {
    // Goal: a cold copy saved by a first run does not stay for good (demo-m4 then pulls every
    // time and misses its 60 s). Method: save a cold image, grow it in the workspace and save
    // again: the store must hold the grown one, restore it, and keep no scratch directory. A
    // workspace that matches, a failed run (`replace_changed` false) and a workspace with no
    // file must each leave the stored copy alone.
    var rig: Rig = undefined;
    try rig.open();
    defer rig.close();
    const io = testing.io;
    const cache = rig.cache();
    const which = growing_entries();
    var data: [16]u8 = undefined;
    try rig.workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "cold" });
    save(&cache, &which, .{ .replace_changed = true });
    try testing.expect(std.mem.indexOf(u8, rig.log.buffered(), "saved") != null);
    // Unchanged: nothing is rewritten.
    rig.log = .fixed(&rig.sink);
    save(&cache, &which, .{ .replace_changed = true });
    try testing.expectEqual(@as(usize, 0), rig.log.buffered().len);
    // Changed, but the steps failed: kept.
    try rig.workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "warm" });
    save(&cache, &which, .{ .replace_changed = false });
    try expect_stored(rig.store, "cold");
    // Changed and the steps passed: replaced, with a list that checks.
    save(&cache, &which, .{ .replace_changed = true });
    try testing.expect(std.mem.indexOf(u8, rig.log.buffered(), "replaced") != null);
    try expect_stored(rig.store, "warm");
    try expect_no_scratch(rig.store);
    try rig.workspace.deleteTree(io, "dl");
    restore(&cache, &which);
    try testing.expectEqualStrings("warm", try rig.workspace.readFile(io, "dl/a-1.img", &data));
    // No file in the workspace: the stored copy stays.
    try rig.workspace.deleteTree(io, "dl");
    try rig.workspace.createDirPath(io, "dl");
    save(&cache, &which, .{ .replace_changed = true });
    try expect_stored(rig.store, "warm");
    try expect_no_scratch(rig.store);
}

test "vm cache: a stored entry with no usable list is replaced, whatever the entry" {
    // Goal: an entry that restore cannot use (no list, a list that does not parse) is rebuilt
    // from the next workspace, even for an entry that does not grow and after a failed run: it is
    // of no use as it is. Method: store, damage the list, save again.
    var rig: Rig = undefined;
    try rig.open();
    defer rig.close();
    const io = testing.io;
    const cache = rig.cache();
    var which = growing_entries();
    which[0].grows = false;
    try rig.workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "good" });
    save(&cache, &which, .{ .replace_changed = false });
    const sums_path = test_key ++ "/" ++ sums_name;
    try rig.store.writeFile(io, .{ .sub_path = sums_path, .data = "not a list\n" });
    save(&cache, &which, .{ .replace_changed = false });
    try testing.expect(std.mem.indexOf(u8, rig.log.buffered(), "replaced") != null);
    var sums: [sums_bytes_max]u8 = undefined;
    try testing.expect(list_is_usable(try rig.store.readFile(io, sums_path, &sums)));
    try expect_stored(rig.store, "good");
    try rig.store.deleteFile(io, test_key ++ "/" ++ sums_name);
    save(&cache, &which, .{ .replace_changed = false });
    try rig.store.access(io, test_key ++ "/" ++ sums_name, .{});
    try expect_no_scratch(rig.store);
}

test "vm cache: save removes the scratch directories a killed save left" {
    // Goal: a save killed between its renames leaves no gigabyte directory behind for good.
    // Method: plant a temporary and a set-aside directory and a file, save: both directories go,
    // the file (not ours to judge) stays, and the entry is stored.
    var rig: Rig = undefined;
    try rig.open();
    defer rig.close();
    const io = testing.io;
    const cache = rig.cache();
    const which = growing_entries();
    try rig.workspace.writeFile(io, .{ .sub_path = "dl/a-1.img", .data = "image" });
    try rig.store.createDirPath(io, "." ++ test_key ++ ".tmp.0000000000000001");
    try rig.store.writeFile(io, .{
        .sub_path = "." ++ test_key ++ ".tmp.0000000000000001/a-1.img",
        .data = "half",
    });
    try rig.store.createDirPath(io, "." ++ test_key ++ ".old.0000000000000002");
    try rig.store.writeFile(io, .{ .sub_path = "note.txt", .data = "x" });
    save(&cache, &which, .{ .replace_changed = true });
    try expect_no_scratch(rig.store);
    try rig.store.access(io, "note.txt", .{});
    try rig.store.access(io, test_key ++ "/" ++ sums_name, .{});
}
