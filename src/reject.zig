const std = @import("std");
const math = std.math;

const spin = @import("spinner.zig");
const gfx = @import("render.zig");

const cell = spin.cell;
const tile_pixels = spin.tile_pixels;
const radius: f32 = spin.radius;

pub const interval_ms = 40;
const morph_ms = 200;
const redden_ms = 600;
const fade_start_ms = redden_ms;
const fade_spread_ms = 120;
const fade_ms = 160;
pub const duration_ms = fade_start_ms + fade_spread_ms + fade_ms;
pub const frame_count = duration_ms / interval_ms;
const morph_frames = morph_ms / interval_ms;

comptime {
    std.debug.assert(duration_ms % interval_ms == 0);
    std.debug.assert(morph_ms % interval_ms == 0);
}

pub const Reject = struct {
    start_ms: ?i64 = null,

    pub fn start(r: *Reject, now_ms: i64) void {
        r.start_ms = now_ms;
    }

    pub fn stop(r: *Reject) void {
        r.start_ms = null;
    }

    pub fn frame(r: Reject, now_ms: i64) ?u8 {
        const k = @divTrunc(elapsed(r.start_ms orelse return null, now_ms), interval_ms);
        return if (k < frame_count) @intCast(k) else null;
    }

    pub fn done(r: Reject, now_ms: i64) bool {
        return elapsed(r.start_ms orelse return false, now_ms) >= duration_ms;
    }

    pub fn timeoutMs(r: Reject, now_ms: i64) ?i32 {
        const e = elapsed(r.start_ms orelse return null, now_ms);
        if (e >= duration_ms) return 0;
        return @intCast(interval_ms - @mod(e, interval_ms));
    }

    fn elapsed(start_ms: i64, now_ms: i64) i64 {
        return @max(0, now_ms - start_ms);
    }
};

const Bang = struct {
    shape: spin.Shape,
    m: f32,

    const dot_y = 0.7 * radius;
    const dot_r = 0.2 * radius;
    const gap = 0.25 * radius;
    const stem_top = -0.85 * radius;
    const stem_bottom = dot_y - dot_r - gap - stem_r_bottom;
    const stem_r_top = 0.2 * radius;
    const stem_r_bottom = 0.13 * radius;

    fn inside(b: Bang, x: f32, y: f32) bool {
        const shape: spin.Shape = .{ .points = b.shape.points, .inner = lerp(b.shape.inner, 1, b.m) };
        if (spin.insideStar(shape, lerp(radius, dot_r, b.m), x, y - b.m * dot_y)) return true;
        if (b.m >= 1 and x * x + (y - dot_y) * (y - dot_y) <= dot_r * dot_r) return true;

        const g = math.clamp((b.m - 0.25) / 0.75, 0, 1);
        if (g == 0) return false;
        const top = lerp(stem_bottom, stem_top, g);
        const thick = @min(1, 3 * g);
        const rt = stem_r_top * thick;
        const rb = stem_r_bottom * thick;
        if (y < top) return x * x + (y - top) * (y - top) <= rt * rt;
        if (y > stem_bottom) return x * x + (y - stem_bottom) * (y - stem_bottom) <= rb * rb;
        const t = (y - top) / (stem_bottom - top);
        return @abs(x) <= lerp(rt, rb, t);
    }
};

pub const Coverage = struct {
    morph: [spin.frames.len][morph_frames][tile_pixels]u8,
    bang: [tile_pixels]u8,

    fn tile(c: *const Coverage, shape: usize, k: usize) *const [tile_pixels]u8 {
        return if (k < morph_frames) &c.morph[shape][k] else &c.bang;
    }
};

pub fn renderCoverage(c: *Coverage) void {
    for (&c.morph, spin.frames) |*tiles, shape| {
        for (tiles, 0..) |*t, k| spin.coverage(t, Bang{ .shape = shape, .m = morph(timeMs(k)) }, Bang.inside);
    }
    spin.coverage(&c.bang, Bang{ .shape = spin.six, .m = 1 }, Bang.inside);
}

pub fn renderStrip(
    strip: []u32,
    count: u32,
    k: usize,
    start: spin.Frame,
    verifying: u24,
    fail: u24,
    c: *const Coverage,
) void {
    const w = spin.stripWidth(count);
    const t = timeMs(k);
    const color = gfx.blend(fail, verifying, smoothstep(@as(f32, @floatFromInt(t)) / redden_ms));
    for (0..count) |i| {
        const shape = (start + spin.frames.len - i % spin.frames.len) % spin.frames.len;
        const cov = c.tile(shape, k);
        const a = alpha(t, i, count);
        for (0..cell) |y| {
            const row = strip[y * w + i * cell ..][0..cell];
            for (row, cov[y * cell ..][0..cell]) |*px, v| {
                px.* = spin.premultiply(color, @intFromFloat(@round(@as(f32, @floatFromInt(v)) * a)));
            }
        }
    }
}

fn timeMs(k: usize) u32 {
    return @intCast(k * interval_ms);
}

fn morph(t: u32) f32 {
    const x = math.clamp(@as(f32, @floatFromInt(t)) / morph_ms, 0, 1);
    return 1 - (1 - x) * (1 - x) * (1 - x);
}

fn alpha(t: u32, i: usize, count: u32) f32 {
    const lag: f32 = if (count > 1)
        fade_spread_ms * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count - 1))
    else
        0;
    const since = @as(f32, @floatFromInt(t)) - fade_start_ms - lag;
    return 1 - math.clamp(since / fade_ms, 0, 1);
}

fn smoothstep(x: f32) f32 {
    const c = math.clamp(x, 0, 1);
    return c * c * (3 - 2 * c);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

const testing = std.testing;

test "Reject: frames on interval boundaries, then done" {
    var r: Reject = .{};
    try testing.expectEqual(@as(?u8, null), r.frame(0));
    try testing.expect(!r.done(0));
    try testing.expectEqual(@as(?i32, null), r.timeoutMs(0));

    r.start(1_000);
    try testing.expectEqual(@as(?u8, 0), r.frame(1_000));
    try testing.expectEqual(@as(?u8, 1), r.frame(1_000 + interval_ms));
    try testing.expectEqual(@as(?u8, frame_count - 1), r.frame(1_000 + duration_ms - 1));
    try testing.expectEqual(@as(?u8, null), r.frame(1_000 + duration_ms));
    try testing.expect(!r.done(1_000 + duration_ms - 1));
    try testing.expect(r.done(1_000 + duration_ms));
    try testing.expectEqual(@as(?i32, 30), r.timeoutMs(1_010));
    try testing.expectEqual(@as(?i32, 0), r.timeoutMs(1_000 + duration_ms));

    r.stop();
    try testing.expect(!r.done(1_000 + duration_ms));
}

test "Bang: m=0 is the star, m=1 is a stem over a dot with a gap" {
    var star: [tile_pixels]u32 = undefined;
    spin.renderStar(&star, spin.six, 0xffffff);
    var cov: [tile_pixels]u8 = undefined;
    spin.coverage(&cov, Bang{ .shape = spin.six, .m = 0 }, Bang.inside);
    for (star, cov) |px, a| try testing.expectEqual(px >> 24, a);

    spin.coverage(&cov, Bang{ .shape = spin.six, .m = 1 }, Bang.inside);
    const c = cell / 2;
    const at = struct {
        fn f(t: *const [tile_pixels]u8, dy: f32) u8 {
            const y: usize = @intFromFloat(@as(f32, c) + dy);
            return t[y * cell + c];
        }
    }.f;
    try testing.expectEqual(@as(u8, 255), at(&cov, Bang.dot_y));
    try testing.expectEqual(@as(u8, 255), at(&cov, -radius / 2));
    try testing.expectEqual(@as(u8, 0), at(&cov, Bang.dot_y - Bang.dot_r - Bang.gap / 2));
    try testing.expectEqual(@as(u8, 0), cov[c]);
    try testing.expectEqual(@as(u8, 0), cov[c * cell]);
}

test "colour: verifying at the start, fail from the fade on" {
    const c = try testing.allocator.create(Coverage);
    defer testing.allocator.destroy(c);
    renderCoverage(c);

    var strip: [tile_pixels]u32 = undefined;
    const centre = (cell / 2 + 2) * cell + cell / 2;
    renderStrip(&strip, 1, 0, 0, 0x0000ff, 0xff0000, c);
    try testing.expectEqual(@as(u32, 0xff0000ff), strip[centre]);

    const dot = @as(usize, @intFromFloat(cell / 2 + Bang.dot_y)) * cell + cell / 2;
    renderStrip(&strip, 1, fade_start_ms / interval_ms - 1, 0, 0x0000ff, 0xff0000, c);
    try testing.expect((strip[dot] >> 16) & 0xff > 0xf0);
    try testing.expect(strip[dot] & 0xff < 0x10);
}

test "fade: left to right, everything gone at the end" {
    try testing.expectEqual(@as(f32, 1), alpha(fade_start_ms, 0, 8));
    const mid = fade_start_ms + fade_ms / 2 + 20;
    try testing.expect(alpha(mid, 0, 8) < alpha(mid, 7, 8));
    for (0..8) |i| try testing.expectEqual(@as(f32, 0), alpha(duration_ms, i, 8));
    try testing.expect(alpha((frame_count - 1) * interval_ms, 7, 8) > 0);
    try testing.expectEqual(@as(f32, 1), alpha(fade_start_ms, 0, 1));
}

test "renderStrip: each star morphs from the shape the spinner left it in" {
    const c = try testing.allocator.create(Coverage);
    defer testing.allocator.destroy(c);
    renderCoverage(c);

    const count = 3;
    var strip: [count * tile_pixels]u32 = undefined;
    renderStrip(&strip, count, 0, 2, 0xffffff, 0xffffff, c);
    for (0..count) |i| {
        var want: [tile_pixels]u32 = undefined;
        spin.renderStar(&want, spin.frames[(2 + spin.frames.len - i) % spin.frames.len], 0xffffff);
        for (0..cell) |y| {
            try testing.expectEqualSlices(u32, want[y * cell ..][0..cell], strip[y * count * cell + i * cell ..][0..cell]);
        }
    }
}
