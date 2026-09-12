const std = @import("std");
const posix = std.posix;
const heap = std.heap;

const Secret = @This();

pub const max_len = 1024;

buf: [max_len]u8 align(heap.page_size_max) = @splat(0),
len: usize = 0,

pub fn init() Secret {
    var secret: Secret = .{};
    lockAgainstSwap(&secret.buf);
    excludeFromCoreDumpsBestEffort(&secret.buf);
    return secret;
}

fn lockAgainstSwap(buf: []align(heap.page_size_max) const u8) void {
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        switch (posix.errno(mlock(buf.ptr, buf.len))) {
            .SUCCESS => return,
            .AGAIN => continue,
            else => |e| std.process.fatal("mlock() on password buffer failed: E{s}", .{@tagName(e)}),
        }
    }
    std.process.fatal("mlock() on password buffer failed: EAGAIN after 10 attempts", .{});
}

fn excludeFromCoreDumpsBestEffort(buf: []align(heap.page_size_max) u8) void {
    posix.madvise(buf.ptr, buf.len, posix.MADV.DONTDUMP) catch |err| {
        std.log.warn("madvise(MADV_DONTDUMP) on password buffer failed: {s}", .{@errorName(err)});
    };
}

extern fn mlock(addr: *const anyopaque, len: usize) c_int;

pub fn append(secret: *Secret, bytes: []const u8) void {
    const room = max_len - secret.len;
    const n = @min(bytes.len, room);

    @memcpy(secret.buf[secret.len..][0..n], bytes[0..n]);
    secret.len += n;
}

pub fn backspace(secret: *Secret) void {
    if (secret.len == 0) return;

    var i = secret.len - 1;
    while (i > 0 and (secret.buf[i] & 0xc0) == 0x80) i -= 1;

    @memset(secret.buf[i..secret.len], 0);
    secret.len = i;
}

pub fn slice(secret: *const Secret) []const u8 {
    return secret.buf[0..secret.len];
}

pub fn isEmpty(secret: *const Secret) bool {
    return secret.len == 0;
}

pub fn clear(secret: *Secret) void {
    std.crypto.secureZero(u8, &secret.buf);
    secret.len = 0;
}

test "append respects the cap without signalling it" {
    var secret: Secret = .{};

    secret.append("hunter2");
    try std.testing.expectEqualStrings("hunter2", secret.slice());

    var long: [max_len * 2]u8 = @splat('x');
    secret.clear();
    secret.append(&long);
    try std.testing.expectEqual(max_len, secret.len);
}

test "backspace removes whole characters" {
    var secret: Secret = .{};

    secret.append("a→");
    try std.testing.expectEqual(@as(usize, 4), secret.len);

    secret.backspace();
    try std.testing.expectEqualStrings("a", secret.slice());

    secret.backspace();
    try std.testing.expect(secret.isEmpty());

    secret.backspace();
    try std.testing.expect(secret.isEmpty());
}

test "init() still behaves like a normal Secret for append/clear" {
    var secret: Secret = .init();

    secret.append("hunter2");
    try std.testing.expectEqualStrings("hunter2", secret.slice());

    secret.clear();
    try std.testing.expect(secret.isEmpty());
}

test "clear zeroes past the current length" {
    var secret: Secret = .{};

    secret.append("a long password");
    secret.clear();
    secret.append("short");

    try std.testing.expect(std.mem.indexOf(u8, &secret.buf, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, &secret.buf, "long") == null);
}
