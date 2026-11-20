//! demo-s2's registry, on the runner (docs/briefs/S2-lazy-start.md, "The demo"): a disk-backed
//! OCI registry the guest reaches over QEMU's user network, so a 3 GiB image needs neither the
//! guest's memory nor the harness's. It takes `zbx push` (blob uploads in pieces, mounts, the
//! manifest) and serves pulls and `Range` reads, with every body paced to one shared rate
//! (`rate_bytes_per_s`), byte counters by kind, and two fault switches the guest flips over HTTP:
//!   - `/_demo/cut-on`, `/_demo/cut-off`: while cut, every other request is closed unanswered,
//!     as a registry that went away looks to a client;
//!   - `/_demo/corrupt?digest=sha256:<hex>&at=<offset>`, `/_demo/honest`: while set, the byte at
//!     that offset of that blob is sent flipped, in whichever body carries it;
//!   - `/_demo/count` prints the counters, `/_demo/reset` zeroes them.
//! One request per connection (`Connection: close`), each on a thread of its own, all bounded:
//! the head, a manifest, the uploads open at once, the connections served at once.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Sha256 = std.crypto.hash.sha2.Sha256;
const wire = @import("registry_server.zig");

/// The throttle of the brief: 40 MiB/s, for all bodies together.
pub const rate_bytes_per_s: u64 = 40 * 1024 * 1024;
const piece_bytes = 64 * 1024;
const io_bytes = 256 * 1024;
const head_bytes_max = 8192;
const manifest_bytes_max = 64 * 1024;
const manifests_max = 8;
const uploads_max = 8;
const connections_max = 64;
const path_bytes_max = 512;
const key_bytes_max = 160;
const hex_bytes = 64;
const no_offset = std.math.maxInt(u64);

const Manifest = struct {
    key: [key_bytes_max]u8 = undefined,
    key_len: u32 = 0,
    digest: [7 + hex_bytes]u8 = undefined,
    media: [128]u8 = undefined,
    media_len: u32 = 0,
    bytes: [manifest_bytes_max]u8 = undefined,
    len: u32 = 0,
};

const Upload = struct {
    fd: i32 = -1,
    size: u64 = 0,
};

pub const Counters = struct {
    manifest: std.atomic.Value(u64) = .init(0),
    whole: std.atomic.Value(u64) = .init(0),
    range: std.atomic.Value(u64) = .init(0),
    ranges: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),

    fn reset(counters: *Counters) void {
        inline for (.{ "manifest", "whole", "range", "ranges", "requests" }) |name| {
            @field(counters, name).store(0, .release);
        }
    }
};

/// Large (the manifests are held in it): keep it in static storage.
pub const Registry = struct {
    listener: i32 = -1,
    port: u16 = 0,
    dir: [path_bytes_max]u8 = undefined,
    dir_len: u32 = 0,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    cut: std.atomic.Value(bool) = .init(false),
    corrupt_at: std.atomic.Value(u64) = .init(no_offset),
    corrupt_hex: [hex_bytes]u8 = @splat('0'),
    pace_next_ns: std.atomic.Value(u64) = .init(0),
    connections: std.atomic.Value(u32) = .init(0),
    counters: Counters = .{},
    locked: std.atomic.Value(bool) = .init(false),
    manifests: [manifests_max]Manifest = @splat(.{}),
    uploads: [uploads_max]Upload = @splat(.{}),

    /// Listens on 127.0.0.1 with an ephemeral port, keeping blobs under `dir` (which exists and
    /// is empty), and serves on a thread of its own until `stop`.
    pub fn start(registry: *Registry, dir: []const u8) !void {
        assert(dir.len > 0 and dir.len < path_bytes_max - 80);
        @memcpy(registry.dir[0..dir.len], dir);
        registry.dir_len = @intCast(dir.len);
        var server: wire.Server = .{};
        try server.bind();
        registry.listener = server.listener;
        registry.port = server.port;
        registry.thread = try std.Thread.spawn(.{}, accept_loop, .{registry});
    }

    pub fn stop(registry: *Registry) void {
        registry.stopping.store(true, .release);
        if (registry.thread) |thread| thread.join();
        registry.thread = null;
        // Connection threads see `stopping` within a poll interval; wait for them.
        for (0..200) |_| {
            if (registry.connections.load(.acquire) == 0) break;
            sleep_ns(10 * std.time.ns_per_ms);
        }
        if (registry.listener >= 0) _ = linux.close(registry.listener);
        registry.listener = -1;
    }

    fn accept_loop(registry: *Registry) void {
        while (!registry.stopping.load(.acquire)) {
            var entries = [1]linux.pollfd{
                .{ .fd = registry.listener, .events = linux.POLL.IN, .revents = 0 },
            };
            const ready = linux.poll(&entries, 1, 20);
            if (linux.errno(ready) != .SUCCESS or ready == 0) continue;
            const accepted = linux.accept4(registry.listener, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) continue;
            const client: i32 = @intCast(accepted);
            if (registry.connections.fetchAdd(1, .acq_rel) >= connections_max) {
                _ = registry.connections.fetchSub(1, .acq_rel);
                _ = linux.close(client);
                continue;
            }
            const thread = std.Thread.spawn(.{}, serve_one, .{ registry, client }) catch {
                _ = registry.connections.fetchSub(1, .acq_rel);
                _ = linux.close(client);
                continue;
            };
            thread.detach();
        }
    }

    fn serve_one(registry: *Registry, client: i32) void {
        defer _ = registry.connections.fetchSub(1, .acq_rel);
        defer _ = linux.close(client);
        registry.handle(client);
    }

    fn handle(registry: *Registry, client: i32) void {
        var request: [head_bytes_max]u8 = undefined;
        var filled: usize = 0;
        const length = wire.read_head(client, &request, &filled, &registry.stopping) orelse return;
        const head = request[0..length];
        const line = head[0..std.mem.indexOf(u8, head, "\r\n").?];
        const parsed = wire.request_line(line) orelse return answer_status(client, 400);
        _ = registry.counters.requests.fetchAdd(1, .monotonic);
        if (std.mem.startsWith(u8, parsed.target, "/_demo/")) {
            return registry.control(client, parsed.target);
        }
        if (registry.cut.load(.acquire)) return; // Closed unanswered.
        const call: Call = .{
            .client = client,
            .method = parsed.method,
            .target = parsed.target,
            .head = head,
            .early = request[length..filled],
        };
        const target = parsed.target;
        if (std.mem.eql(u8, target, "/v2/") or std.mem.eql(u8, target, "/v2")) {
            return answer(client, .{ .status = 200, .content_type = "application/json" }, "{}");
        }
        if (std.mem.indexOf(u8, target, "/blobs/uploads/")) |at| return registry.upload(call, at);
        if (std.mem.indexOf(u8, target, "/blobs/")) |at| return registry.blob(call, at);
        if (std.mem.indexOf(u8, target, "/manifests/")) |at| return registry.manifest(call, at);
        answer_status(client, 404);
    }

    fn control(registry: *Registry, client: i32, target: []const u8) void {
        const name = target["/_demo/".len..];
        if (std.mem.eql(u8, name, "cut-on")) registry.cut.store(true, .release);
        if (std.mem.eql(u8, name, "cut-off")) registry.cut.store(false, .release);
        if (std.mem.eql(u8, name, "honest")) registry.corrupt_at.store(no_offset, .release);
        if (std.mem.eql(u8, name, "reset")) registry.counters.reset();
        if (std.mem.startsWith(u8, name, "corrupt?")) {
            const hex = digest_hex(query_value(name, "digest")) orelse {
                return answer_status(client, 400);
            };
            const at = std.fmt.parseInt(u64, query_value(name, "at"), 10) catch {
                return answer_status(client, 400);
            };
            registry.corrupt_at.store(no_offset, .release);
            @memcpy(&registry.corrupt_hex, hex);
            registry.corrupt_at.store(at, .release);
        }
        var text: [256]u8 = undefined;
        const c = &registry.counters;
        const body = std.fmt.bufPrint(
            &text,
            "manifest={d} whole={d} range={d} ranges={d} requests={d} cut={} corrupt={}\n",
            .{
                c.manifest.load(.acquire),   c.whole.load(.acquire),
                c.range.load(.acquire),      c.ranges.load(.acquire),
                c.requests.load(.acquire),   registry.cut.load(.acquire),
                registry.corrupt_at.load(.acquire) != no_offset,
            },
        ) catch unreachable; // The buffer fits.
        answer(client, .{ .status = 200, .content_type = "text/plain" }, body);
    }

    /// `GET` or `HEAD` of `/v2/<repo>/blobs/sha256:<hex>`, whole or by `Range`.
    fn blob(registry: *Registry, call: Call, at: usize) void {
        if (call.method != .get and call.method != .head) return answer_status(call.client, 404);
        const digest = call.target[at + "/blobs/".len ..];
        const hex = digest_hex(digest) orelse return answer_status(call.client, 404);
        var path: [path_bytes_max]u8 = undefined;
        const fd = open_file(registry.blob_path(&path, hex), .{ .ACCMODE = .RDONLY }) orelse {
            return answer_status(call.client, 404);
        };
        defer _ = linux.close(fd);
        const size = file_size(fd);
        var first: u64 = 0;
        var end: u64 = size;
        const range = wire.header_value(call.head, "range");
        if (range) |text| {
            const asked = parse_range(text, size) orelse return answer_status(call.client, 416);
            first = asked.first;
            end = asked.end;
        }
        var content_range: [96]u8 = undefined;
        const head: Head = .{
            .status = if (range == null) 200 else 206,
            .content_type = "application/octet-stream",
            .digest = digest,
            .content_range = if (range == null) "" else std.fmt.bufPrint(
                &content_range,
                "bytes {d}-{d}/{d}",
                .{ first, end - 1, size },
            ) catch unreachable, // The buffer fits.
            .length = end - first,
        };
        write_head(call.client, head);
        if (call.method == .head) return;
        const counter = if (range == null) &registry.counters.whole else &registry.counters.range;
        if (range != null) _ = registry.counters.ranges.fetchAdd(1, .monotonic);
        registry.send_file(call.client, fd, hex, first, end, counter);
    }

    /// Sends `[first, end)` of a blob in paced pieces, flipping the corrupt byte if it is there.
    fn send_file(
        registry: *Registry,
        client: i32,
        fd: i32,
        hex: []const u8,
        first: u64,
        end: u64,
        counter: *std.atomic.Value(u64),
    ) void {
        var buffer: [piece_bytes]u8 = undefined;
        var at = first;
        while (at < end) {
            const want: usize = @intCast(@min(end - at, piece_bytes));
            const got = linux.pread(fd, &buffer, want, @intCast(at));
            if (linux.errno(got) != .SUCCESS or got == 0) return;
            const piece = buffer[0..got];
            const bad = registry.corrupt_at.load(.acquire);
            if (bad != no_offset and bad >= at and bad < at + got and
                std.mem.eql(u8, hex, &registry.corrupt_hex))
            {
                piece[@intCast(bad - at)] ^= 0x5a;
            }
            registry.pace(got);
            if (registry.cut.load(.acquire)) return;
            if (!send_all(client, piece)) return;
            _ = counter.fetchAdd(got, .monotonic);
            at += got;
        }
    }

    /// Waits for this piece's turn at `rate_bytes_per_s`, shared by every connection.
    fn pace(registry: *Registry, bytes: usize) void {
        const cost = @as(u64, bytes) * std.time.ns_per_s / rate_bytes_per_s;
        while (true) {
            const now = now_ns();
            const next = registry.pace_next_ns.load(.acquire);
            const begin = @max(now, next);
            const swapped = registry.pace_next_ns.cmpxchgWeak(next, begin + cost, .acq_rel, .acquire);
            if (swapped != null) continue;
            if (begin > now) sleep_ns(begin - now);
            return;
        }
    }

    fn blob_path(registry: *const Registry, buffer: []u8, name: []const u8) [:0]const u8 {
        const dir = registry.dir[0..registry.dir_len];
        return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ dir, name }) catch unreachable; // Short.
    }

    fn lock(registry: *Registry) void {
        while (registry.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(registry: *Registry) void {
        registry.locked.store(false, .release);
    }

    /// `POST .../blobs/uploads/` (a mount or a new session), `PATCH` and the closing `PUT`.
    fn upload(registry: *Registry, call: Call, at: usize) void {
        const repo = call.target[0..at];
        const rest = call.target[at + "/blobs/uploads/".len ..];
        switch (call.method) {
            .post => registry.upload_open(call, repo, rest),
            .patch, .put => {
                const end = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
                const slot = std.fmt.parseInt(u32, rest[0..end], 10) catch {
                    return answer_status(call.client, 404);
                };
                if (slot >= uploads_max) return answer_status(call.client, 404);
                registry.upload_piece(call, repo, slot, rest[end..]);
            },
            else => answer_status(call.client, 404),
        }
    }

    fn upload_open(registry: *Registry, call: Call, repo: []const u8, query: []const u8) void {
        const mount = query_value(query, "mount");
        if (digest_hex(mount)) |hex| {
            var path: [path_bytes_max]u8 = undefined;
            if (open_file(registry.blob_path(&path, hex), .{ .ACCMODE = .RDONLY })) |fd| {
                _ = linux.close(fd);
                var location: [path_bytes_max]u8 = undefined;
                const where = std.fmt.bufPrint(&location, "{s}/blobs/{s}", .{ repo, mount }) catch {
                    return answer_status(call.client, 400);
                };
                return write_head(call.client, .{
                    .status = 201,
                    .location = where,
                    .digest = mount,
                });
            }
        }
        registry.lock();
        const slot = for (&registry.uploads, 0..) |*held, index| {
            if (held.fd == -1) {
                held.fd = -2; // Taken; opened below.
                break index;
            }
        } else null;
        registry.unlock();
        const index = slot orelse return answer_status(call.client, 429);
        var name: [32]u8 = undefined;
        var path: [path_bytes_max]u8 = undefined;
        const file = std.fmt.bufPrint(&name, "upload-{d}", .{index}) catch unreachable; // Short.
        const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
        const fd = open_file(registry.blob_path(&path, file), flags) orelse {
            registry.uploads[index].fd = -1;
            return answer_status(call.client, 500);
        };
        registry.uploads[index] = .{ .fd = fd, .size = 0 };
        var location: [path_bytes_max]u8 = undefined;
        const where = std.fmt.bufPrint(&location, "{s}/blobs/uploads/{d}", .{ repo, index }) catch {
            return answer_status(call.client, 400);
        };
        write_head(call.client, .{ .status = 202, .location = where });
    }

    /// A `PATCH` piece, or the `PUT` that ends the session with an optional last piece.
    fn upload_piece(registry: *Registry, call: Call, repo: []const u8, slot: u32, query: []const u8) void {
        const held = &registry.uploads[slot];
        if (held.fd < 0) return answer_status(call.client, 404);
        const declared = wire.header_value(call.head, "content-length") orelse "0";
        const size = std.fmt.parseInt(u64, declared, 10) catch return answer_status(call.client, 400);
        if (wire.header_value(call.head, "content-range")) |text| {
            const dash = std.mem.indexOfScalar(u8, text, '-') orelse return answer_status(call.client, 400);
            const from = std.fmt.parseInt(u64, text[0..dash], 10) catch {
                return answer_status(call.client, 400);
            };
            if (from != held.size) return answer_status(call.client, 416);
        }
        if (!registry.receive(call, held.fd, held.size, size)) return;
        held.size += size;
        var location: [path_bytes_max]u8 = undefined;
        const where = std.fmt.bufPrint(&location, "{s}/blobs/uploads/{d}", .{ repo, slot }) catch {
            return answer_status(call.client, 400);
        };
        if (call.method == .patch) {
            var range: [48]u8 = undefined;
            const last = if (held.size == 0) 0 else held.size - 1;
            const held_range = std.fmt.bufPrint(&range, "0-{d}", .{last}) catch unreachable;
            return write_head(call.client, .{ .status = 202, .location = where, .range = held_range });
        }
        registry.upload_close(call, repo, slot, query_value(query, "digest"));
    }

    fn upload_close(registry: *Registry, call: Call, repo: []const u8, slot: u32, digest: []const u8) void {
        const held = &registry.uploads[slot];
        defer {
            _ = linux.close(held.fd);
            registry.lock();
            held.* = .{};
            registry.unlock();
        }
        var name: [32]u8 = undefined;
        var from: [path_bytes_max]u8 = undefined;
        var to: [path_bytes_max]u8 = undefined;
        const file = std.fmt.bufPrint(&name, "upload-{d}", .{slot}) catch unreachable; // Short.
        const upload_path = registry.blob_path(&from, file);
        const hex = digest_hex(digest) orelse return answer_status(call.client, 400);
        var computed: [hex_bytes]u8 = undefined;
        if (!hash_file(held.fd, held.size, &computed) or !std.mem.eql(u8, &computed, hex)) {
            _ = linux.unlinkat(linux.AT.FDCWD, upload_path, 0);
            return answer_status(call.client, 400);
        }
        const renamed = linux.renameat(
            linux.AT.FDCWD,
            upload_path,
            linux.AT.FDCWD,
            registry.blob_path(&to, hex),
        );
        if (linux.errno(renamed) != .SUCCESS) return answer_status(call.client, 500);
        var location: [path_bytes_max]u8 = undefined;
        const where = std.fmt.bufPrint(&location, "{s}/blobs/{s}", .{ repo, digest }) catch {
            return answer_status(call.client, 400);
        };
        write_head(call.client, .{ .status = 201, .location = where, .digest = digest });
    }

    /// Writes a request's body of `size` bytes to `fd` at `offset`: the bytes read with the head,
    /// then the rest from the connection.
    fn receive(registry: *Registry, call: Call, fd: i32, offset: u64, size: u64) bool {
        const early = call.early[0..@intCast(@min(call.early.len, size))];
        if (!write_at(fd, early, offset)) return false;
        var buffer: [io_bytes]u8 = undefined;
        var done: u64 = early.len;
        while (done < size) {
            const want: usize = @intCast(@min(size - done, io_bytes));
            if (!wire.read_exact(call.client, buffer[0..want], &registry.stopping)) return false;
            if (!write_at(fd, buffer[0..want], offset + done)) return false;
            done += want;
        }
        return true;
    }

    /// `PUT` (by tag), `GET` and `HEAD` (by tag or digest) of `/v2/<repo>/manifests/<ref>`.
    fn manifest(registry: *Registry, call: Call, at: usize) void {
        const repo = call.target[0..at];
        const reference = call.target[at + "/manifests/".len ..];
        var key: [key_bytes_max]u8 = undefined;
        const name = std.fmt.bufPrint(&key, "{s}@{s}", .{ repo, reference }) catch {
            return answer_status(call.client, 404);
        };
        if (call.method == .put) return registry.manifest_put(call, repo, name);
        if (call.method != .get and call.method != .head) return answer_status(call.client, 404);
        registry.lock();
        const found = registry.find(name);
        registry.unlock();
        const held = found orelse return answer_status(call.client, 404);
        // A held manifest is never changed or removed, so it is read outside the lock.
        write_head(call.client, .{
            .status = 200,
            .content_type = held.media[0..held.media_len],
            .digest = &held.digest,
            .length = held.len,
        });
        if (call.method == .head) return;
        registry.pace(held.len);
        if (send_all(call.client, held.bytes[0..held.len])) {
            _ = registry.counters.manifest.fetchAdd(held.len, .monotonic);
        }
    }

    fn manifest_put(registry: *Registry, call: Call, repo: []const u8, name: []const u8) void {
        const declared = wire.header_value(call.head, "content-length") orelse "0";
        const size = std.fmt.parseInt(u32, declared, 10) catch return answer_status(call.client, 400);
        if (size > manifest_bytes_max) return answer_status(call.client, 413);
        const media = wire.header_value(call.head, "content-type") orelse "";
        if (media.len > 128) return answer_status(call.client, 400);
        var body: [manifest_bytes_max]u8 = undefined;
        const kept = @min(call.early.len, size);
        @memcpy(body[0..kept], call.early[0..kept]);
        if (!wire.read_exact(call.client, body[kept..size], &registry.stopping)) return;
        var sum: [32]u8 = undefined;
        Sha256.hash(body[0..size], &sum, .{});
        var digest: [7 + hex_bytes]u8 = undefined;
        _ = std.fmt.bufPrint(&digest, "sha256:{x}", .{&sum}) catch unreachable; // It fits.
        var by_digest: [key_bytes_max]u8 = undefined;
        const digest_key = std.fmt.bufPrint(&by_digest, "{s}@{s}", .{ repo, &digest }) catch {
            return answer_status(call.client, 400);
        };
        registry.lock();
        const stored = registry.store(name, &digest, media, body[0..size]) and
            registry.store(digest_key, &digest, media, body[0..size]);
        registry.unlock();
        if (!stored) return answer_status(call.client, 507);
        var location: [path_bytes_max]u8 = undefined;
        const where = std.fmt.bufPrint(&location, "{s}/manifests/{s}", .{ repo, &digest }) catch {
            return answer_status(call.client, 400);
        };
        write_head(call.client, .{ .status = 201, .location = where, .digest = &digest });
    }

    fn find(registry: *Registry, key: []const u8) ?*const Manifest {
        for (&registry.manifests) |*held| {
            if (held.key_len > 0 and std.mem.eql(u8, held.key[0..held.key_len], key)) return held;
        }
        return null;
    }

    /// Holds a manifest under `key` once; a key held already keeps its first manifest, which the
    /// demo never replaces. False when every slot is taken.
    fn store(
        registry: *Registry,
        key: []const u8,
        digest: []const u8,
        media: []const u8,
        bytes: []const u8,
    ) bool {
        if (registry.find(key) != null) return true;
        for (&registry.manifests) |*held| {
            if (held.key_len != 0) continue;
            @memcpy(held.key[0..key.len], key);
            @memcpy(&held.digest, digest);
            @memcpy(held.media[0..media.len], media);
            held.media_len = @intCast(media.len);
            @memcpy(held.bytes[0..bytes.len], bytes);
            held.len = @intCast(bytes.len);
            held.key_len = @intCast(key.len);
            return true;
        }
        return false;
    }
};

const Call = struct {
    client: i32,
    method: @import("push_fixture.zig").Method,
    target: []const u8,
    head: []const u8,
    early: []const u8,
};

const Head = struct {
    status: u16,
    content_type: []const u8 = "",
    digest: []const u8 = "",
    location: []const u8 = "",
    range: []const u8 = "",
    content_range: []const u8 = "",
    length: u64 = 0,
};

fn write_head(client: i32, head: Head) void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    write_head_to(&writer, head) catch unreachable; // The buffer fits every head made here.
    _ = send_all(client, writer.buffered());
}

fn write_head_to(writer: *std.Io.Writer, head: Head) std.Io.Writer.Error!void {
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ head.status, wire.reason(head.status) });
    const optional = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Content-Type", .value = head.content_type },
        .{ .name = "Docker-Content-Digest", .value = head.digest },
        .{ .name = "Location", .value = head.location },
        .{ .name = "Range", .value = head.range },
        .{ .name = "Content-Range", .value = head.content_range },
    };
    for (optional) |header| {
        if (header.value.len > 0) try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try writer.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{head.length});
}

fn answer(client: i32, head: Head, body: []const u8) void {
    var with_length = head;
    with_length.length = body.len;
    write_head(client, with_length);
    _ = send_all(client, body);
}

fn answer_status(client: i32, status: u16) void {
    write_head(client, .{ .status = status });
}

fn send_all(client: i32, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const rest = bytes[at..];
        const rc = linux.sendto(client, rest.ptr, rest.len, linux.MSG.NOSIGNAL, null, 0);
        if (linux.errno(rc) != .SUCCESS) return false;
        at += rc;
    }
    return true;
}

fn write_at(fd: i32, bytes: []const u8, offset: u64) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const rest = bytes[at..];
        const rc = linux.pwrite(fd, rest.ptr, rest.len, @intCast(offset + at));
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        at += rc;
    }
    return true;
}

fn hash_file(fd: i32, size: u64, out: *[hex_bytes]u8) bool {
    var hasher = Sha256.init(.{});
    var buffer: [io_bytes]u8 = undefined;
    var at: u64 = 0;
    while (at < size) {
        const want: usize = @intCast(@min(size - at, io_bytes));
        const got = linux.pread(fd, &buffer, want, @intCast(at));
        if (linux.errno(got) != .SUCCESS or got == 0) return false;
        hasher.update(buffer[0..got]);
        at += got;
    }
    _ = std.fmt.bufPrint(out, "{x}", .{&hasher.finalResult()}) catch unreachable; // It fits.
    return true;
}

fn open_file(path: [:0]const u8, flags: linux.O) ?i32 {
    var with_cloexec = flags;
    with_cloexec.CLOEXEC = true;
    const rc = linux.openat(linux.AT.FDCWD, path, with_cloexec, 0o644);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn file_size(fd: i32) u64 {
    const rc = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(@intCast(rc)) != .SUCCESS) return 0;
    return rc;
}

/// The 64 lower-case hex digits of `sha256:<hex>`, or null for anything else.
fn digest_hex(digest: []const u8) ?[]const u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return null;
    const hex = digest[prefix.len..];
    if (hex.len != hex_bytes) return null;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return null;
    }
    return hex;
}

/// The value of `name` in a `?a=b&c=d` query (anything before `?` is skipped); empty if absent.
fn query_value(text: []const u8, name: []const u8) []const u8 {
    const start = (std.mem.indexOfScalar(u8, text, '?') orelse return "") + 1;
    var pairs = std.mem.splitScalar(u8, text[start..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return "";
}

const Asked = struct { first: u64, end: u64 };

/// `bytes=a-b` or `bytes=a-` within a blob of `size` bytes, as `[first, end)`; null for any
/// other form or a range that starts past the end.
fn parse_range(text: []const u8, size: u64) ?Asked {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const first = std.fmt.parseInt(u64, rest[0..dash], 10) catch return null;
    if (first >= size) return null;
    const last_text = rest[dash + 1 ..];
    if (last_text.len == 0) return .{ .first = first, .end = size };
    const last = std.fmt.parseInt(u64, last_text, 10) catch return null;
    if (last < first) return null;
    return .{ .first = first, .end = @min(last + 1, size) };
}

fn now_ns() u64 {
    var stamp: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &stamp);
    return @as(u64, @intCast(stamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(stamp.nsec));
}

fn sleep_ns(ns: u64) void {
    const request: linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

test "parse_range, query_value and digest_hex" {
    // Goal: the three small parsers the registry trusts, at their edges.
    const asked = parse_range("bytes=10-19", 100).?;
    try std.testing.expectEqual(@as(u64, 10), asked.first);
    try std.testing.expectEqual(@as(u64, 20), asked.end);
    try std.testing.expectEqual(@as(u64, 100), parse_range("bytes=90-", 100).?.end);
    try std.testing.expectEqual(@as(u64, 100), parse_range("bytes=90-500", 100).?.end);
    try std.testing.expect(parse_range("bytes=100-", 100) == null);
    try std.testing.expect(parse_range("bytes=5-4", 100) == null);
    try std.testing.expect(parse_range("items=0-1", 100) == null);
    try std.testing.expectEqualStrings("b", query_value("x?a=1&mount=b", "mount"));
    try std.testing.expectEqualStrings("", query_value("x?a=1", "mount"));
    try std.testing.expectEqualStrings("", query_value("x", "mount"));
    const hex = "ab" ** 32;
    try std.testing.expectEqualStrings(hex, digest_hex("sha256:" ++ hex).?);
    try std.testing.expect(digest_hex("sha256:" ++ "AB" ** 32) == null);
    try std.testing.expect(digest_hex("sha512:" ++ hex) == null);
}
