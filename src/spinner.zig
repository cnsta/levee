const std = @import("std");
const math = std.math;

pub const Shape = struct {
    points: u8,
    inner: f32,
};

const six: Shape = .{ .points = 6, .inner = 0.5 }; // ✶
const eight_heavy: Shape = .{ .points = 8, .inner = 0.5 }; // ✸
const twelve: Shape = .{ .points = 12, .inner = 0.6 }; // ✹
const sixteen: Shape = .{ .points = 16, .inner = 0.4 }; // ✺
const eight: Shape = .{ .points = 8, .inner = 0.38 }; // ✷

/// the star spinner: ✶ ✸ ✹ ✺ ✹ ✷.
pub const frames = [_]Shape{ six, eight_heavy, twelve, sixteen, twelve, eight };

pub const Frame = math.IntFittingRange(0, frames.len - 1);

pub const interval_ms = 80;
pub const cycle_ms = interval_ms * frames.len;

/// one star per typed character, a square cell as wide as the password row's
/// glyph advance.
pub const cell = 24;
const radius = 9.0;
pub const max_stars = 64;
pub const tile_pixels = cell * cell;

pub fn stripWidth(count: u32) u32 {
    return count * cell;
}

/// stars for a submitted secret: one per codepoint, at least one (an empty
/// submission still shows progress), capped to bound the buffers.
pub fn starCount(secret: []const u8) u32 {
    const n = std.unicode.utf8CountCodepoints(secret) catch secret.len;
    return @intCast(math.clamp(n, 1, max_stars));
}

pub const Spinner = struct {
    start_ms: ?i64 = null,

    pub fn start(s: *Spinner, now_ms: i64) void {
        s.start_ms = now_ms;
    }

    pub fn stop(s: *Spinner) void {
        s.start_ms = null;
    }

    pub fn frame(s: Spinner, now_ms: i64) ?Frame {
        const steps = @divTrunc(elapsed(s.start_ms orelse return null, now_ms), interval_ms);
        return @intCast(@mod(steps, frames.len));
    }

    pub fn timeoutMs(s: Spinner, now_ms: i64) ?i32 {
        const e = elapsed(s.start_ms orelse return null, now_ms);
        return @intCast(interval_ms - @mod(e, interval_ms));
    }

    pub fn cycleEndMs(s: Spinner) ?i64 {
        return (s.start_ms orelse return null) + cycle_ms;
    }

    fn elapsed(start_ms: i64, now_ms: i64) i64 {
        return @max(0, now_ms - start_ms);
    }
};

pub fn renderStar(tile: *[tile_pixels]u32, shape: Shape, color: u24) void {
    const samples = 4;
    const c: f32 = cell / 2.0;
    for (0..cell) |y| {
        for (0..cell) |x| {
            var hits: u32 = 0;
            for (0..samples) |sy| {
                for (0..samples) |sx| {
                    const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples;
                    const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples;
                    if (insideStar(shape, px - c, py - c)) hits += 1;
                }
            }
            tile[y * cell + x] = premultiply(color, @intCast(hits * 255 / (samples * samples)));
        }
    }
}

fn insideStar(shape: Shape, x: f32, y: f32) bool {
    const n: usize = 2 * @as(usize, shape.points);
    const step = math.pi / @as(f32, @floatFromInt(shape.points));
    var inside = false;
    var prev = vertex(shape, n - 1, step);
    for (0..n) |i| {
        const cur = vertex(shape, i, step);
        if ((cur[1] > y) != (prev[1] > y)) {
            const cross_x = cur[0] + (y - cur[1]) * (prev[0] - cur[0]) / (prev[1] - cur[1]);
            if (x < cross_x) inside = !inside;
        }
        prev = cur;
    }
    return inside;
}

fn vertex(shape: Shape, i: usize, step: f32) [2]f32 {
    const r: f32 = if (i % 2 == 0) radius else radius * shape.inner;
    const a = -math.pi / 2.0 + step * @as(f32, @floatFromInt(i));
    return .{ r * @cos(a), r * @sin(a) };
}

pub fn renderStrip(strip: []u32, count: u32, k: Frame, tiles: *const [frames.len][tile_pixels]u32) void {
    const w = stripWidth(count);
    for (0..count) |i| {
        const tile = &tiles[(k + frames.len - i % frames.len) % frames.len];
        for (0..cell) |y| {
            @memcpy(strip[y * w + i * cell ..][0..cell], tile[y * cell ..][0..cell]);
        }
    }
}

pub fn renderTiles(tiles: *[frames.len][tile_pixels]u32, color: u24) void {
    for (tiles, frames) |*tile, shape| renderStar(tile, shape, color);
}

fn premultiply(color: u24, a: u8) u32 {
    var px: u32 = @as(u32, a) << 24;
    inline for (.{ 16, 8, 0 }) |shift| {
        const ch: u32 = (color >> shift) & 0xff;
        px |= ((ch * a + 127) / 255) << shift;
    }
    return px;
}

const testing = std.testing;

test "frames are the star-1 sequence" {
    try testing.expectEqual(6, frames.len);
    try testing.expectEqual(@as(u8, 6), frames[0].points);
    try testing.expectEqual(@as(u8, 16), frames[3].points);
    try testing.expectEqual(frames[2], frames[4]);
    try testing.expectEqual(@as(u8, 8), frames[5].points);
}

test "starCount: one per codepoint, at least one, capped" {
    try testing.expectEqual(@as(u32, 1), starCount(""));
    try testing.expectEqual(@as(u32, 3), starCount("abc"));
    try testing.expectEqual(@as(u32, 2), starCount("åä"));
    try testing.expectEqual(@as(u32, max_stars), starCount("x" ** (max_stars + 5)));
}

test "Spinner: frames advance on interval boundaries and wrap per cycle" {
    var s: Spinner = .{};
    try testing.expectEqual(@as(?Frame, null), s.frame(0));
    try testing.expectEqual(@as(?i32, null), s.timeoutMs(0));

    s.start(1_000);
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000));
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000 + interval_ms - 1));
    try testing.expectEqual(@as(?Frame, 1), s.frame(1_000 + interval_ms));
    try testing.expectEqual(@as(?Frame, 5), s.frame(1_000 + cycle_ms - 1));
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000 + cycle_ms));
    try testing.expectEqual(@as(?Frame, 0), s.frame(500));

    try testing.expectEqual(@as(?i32, interval_ms), s.timeoutMs(1_000));
    try testing.expectEqual(@as(?i32, 30), s.timeoutMs(1_050));
    try testing.expectEqual(@as(?i64, 1_000 + cycle_ms), s.cycleEndMs());

    s.stop();
    try testing.expectEqual(@as(?i64, null), s.cycleEndMs());
}

test "renderStar: solid centre, clear corners, tips reach out, premultiplied" {
    var tile: [tile_pixels]u32 = undefined;
    renderStar(&tile, six, 0x6faad1);

    const c = cell / 2;
    try testing.expectEqual(@as(u32, 0xff6faad1), tile[c * cell + c]);
    try testing.expectEqual(@as(u32, 0), tile[0]);
    try testing.expectEqual(@as(u32, 0), tile[tile_pixels - 1]);

    const r = @as(usize, @intFromFloat(radius * 0.8));
    try testing.expect(tile[(c - r) * cell + c] >> 24 > 0);
    const valley = math.pi / 6.0 - math.pi / 2.0;
    const vx: usize = @intFromFloat(@as(f32, c) + radius * 0.8 * @cos(valley));
    const vy: usize = @intFromFloat(@as(f32, c) + radius * 0.8 * @sin(valley));
    try testing.expectEqual(@as(u32, 0), tile[vy * cell + vx] >> 24);

    var partial = false;
    for (tile) |px| {
        const a = px >> 24;
        if (a > 0 and a < 255) partial = true;
        inline for (.{ 16, 8, 0 }) |shift| try testing.expect((px >> shift) & 0xff <= a);
    }
    try testing.expect(partial);
}

test "renderStrip: star i of wave frame k shows frame k - i" {
    var tiles: [frames.len][tile_pixels]u32 = undefined;
    for (&tiles, 0..) |*t, i| @memset(t, @intCast(i + 1));

    const count = 8;
    var strip: [count * tile_pixels]u32 = undefined;
    renderStrip(&strip, count, 4, &tiles);
    for (0..count) |i| {
        const want: u32 = @intCast((4 + frames.len - i % frames.len) % frames.len + 1);
        try testing.expectEqual(want, strip[i * cell]);
        try testing.expectEqual(want, strip[(cell - 1) * stripWidth(count) + i * cell + cell - 1]);
    }
}
