const std = @import("std");
const math = std.math;

pub const frames = blk: {
    const glyphs = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    var masks: [10]u6 = undefined;
    var it = std.unicode.Utf8View.initComptime(glyphs).iterator();
    for (&masks) |*m| m.* = @intCast(it.nextCodepoint().? - 0x2800);
    if (it.nextCodepoint() != null) @compileError("frame count mismatch");
    break :blk masks;
};

pub const Frame = math.IntFittingRange(0, frames.len - 1);

pub const interval_ms = 80;
pub const cycle_ms = interval_ms * frames.len;

const pitch = 12;
const radius = 4;
pub const width = 2 * pitch;
pub const height = 3 * pitch;
pub const stride = width * 4;
pub const frame_pixels = width * height;

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

pub fn renderFrame(pixels: []u32, mask: u6, color: u24) void {
    @memset(pixels, 0);
    for (0..6) |dot| {
        if (mask & (@as(u6, 1) << @intCast(dot)) == 0) continue;
        const cx: f32 = @floatFromInt(pitch / 2 + pitch * (dot / 3));
        const cy: f32 = @floatFromInt(pitch / 2 + pitch * (dot % 3));
        const x0: usize = @intFromFloat(cx - radius - 1);
        const y0: usize = @intFromFloat(cy - radius - 1);
        for (y0..y0 + 2 * radius + 2) |y| {
            for (x0..x0 + 2 * radius + 2) |x| {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const cov = math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
                if (cov > 0) pixels[y * width + x] = premultiply(color, @intFromFloat(@round(cov * 255)));
            }
        }
    }
}

fn premultiply(color: u24, a: u8) u32 {
    var px: u32 = @as(u32, a) << 24;
    inline for (.{ 16, 8, 0 }) |shift| {
        const c: u32 = (color >> shift) & 0xff;
        px |= ((c * a + 127) / 255) << shift;
    }
    return px;
}

const testing = std.testing;

test "frames decode the braille dots spinner" {
    try testing.expectEqual(@as(u6, 0b001011), frames[0]); // ⠋ dots 1 2 4
    try testing.expectEqual(@as(u6, 0b000111), frames[8]); // ⠇ dots 1 2 3
    try testing.expectEqual(@as(u6, 0b001111), frames[9]); // ⠏ dots 1 2 3 4
}

test "Spinner: frames advance on interval boundaries and wrap per cycle" {
    var s: Spinner = .{};
    try testing.expectEqual(@as(?Frame, null), s.frame(0));
    try testing.expectEqual(@as(?i32, null), s.timeoutMs(0));

    s.start(1_000);
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000));
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000 + interval_ms - 1));
    try testing.expectEqual(@as(?Frame, 1), s.frame(1_000 + interval_ms));
    try testing.expectEqual(@as(?Frame, 9), s.frame(1_000 + cycle_ms - 1));
    try testing.expectEqual(@as(?Frame, 0), s.frame(1_000 + cycle_ms));
    try testing.expectEqual(@as(?Frame, 0), s.frame(500));

    try testing.expectEqual(@as(?i32, interval_ms), s.timeoutMs(1_000));
    try testing.expectEqual(@as(?i32, 30), s.timeoutMs(1_050));
    try testing.expectEqual(@as(?i64, 1_000 + cycle_ms), s.cycleEndMs());

    s.stop();
    try testing.expectEqual(@as(?i64, null), s.cycleEndMs());
}

test "renderFrame: lit dots opaque, unlit transparent, premultiplied" {
    var pixels: [frame_pixels]u32 = undefined;
    renderFrame(&pixels, 0b000001, 0x6faad1);

    const centre = pitch / 2;
    try testing.expectEqual(@as(u32, 0xff6faad1), pixels[centre * width + centre]);
    try testing.expectEqual(@as(u32, 0), pixels[centre * width + centre + pitch]);
    try testing.expectEqual(@as(u32, 0), pixels[(centre + pitch) * width + centre]);

    var partial = false;
    for (pixels) |px| {
        const a = px >> 24;
        if (a > 0 and a < 255) partial = true;
        inline for (.{ 16, 8, 0 }) |shift| try testing.expect((px >> shift) & 0xff <= a);
    }
    try testing.expect(partial);
}
