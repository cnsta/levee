const std = @import("std");
const math = std.math;

const Font = @import("render/font.zig");

pub const Color = u24;

pub const Canvas = struct {
    pixels: []u32,
    width: u31,
    height: u31,

    pub fn fill(canvas: Canvas, color: Color) void {
        @memset(canvas.pixels, @as(u32, color));
    }

    fn set(canvas: Canvas, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= canvas.width or y >= canvas.height) return;
        canvas.pixels[@as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x))] = color;
    }

    pub fn fillRect(canvas: Canvas, x0: i32, y0: i32, w: i32, h: i32, color: Color) void {
        var y = y0;
        while (y < y0 + h) : (y += 1) {
            var x = x0;
            while (x < x0 + w) : (x += 1) canvas.set(x, y, color);
        }
    }

    pub fn drawDisk(canvas: Canvas, cx: f32, cy: f32, radius: f32, color: Color, bg: Color) void {
        canvas.drawAnnulus(cx, cy, 0, radius, 0, math.tau, color, bg);
    }

    pub fn drawRing(canvas: Canvas, cx: f32, cy: f32, inner: f32, outer: f32, color: Color, bg: Color) void {
        canvas.drawAnnulus(cx, cy, inner, outer, 0, math.tau, color, bg);
    }

    pub fn drawArc(
        canvas: Canvas,
        cx: f32,
        cy: f32,
        inner: f32,
        outer: f32,
        start_rad: f32,
        sweep_rad: f32,
        color: Color,
        bg: Color,
    ) void {
        canvas.drawAnnulus(cx, cy, inner, outer, start_rad, sweep_rad, color, bg);
    }

    fn drawAnnulus(
        canvas: Canvas,
        cx: f32,
        cy: f32,
        inner: f32,
        outer: f32,
        start_rad: f32,
        sweep_rad: f32,
        color: Color,
        bg: Color,
    ) void {
        const full_circle = sweep_rad >= math.tau;
        const start = normalizeAngle(start_rad);

        const bound: i32 = @intFromFloat(@ceil(outer) + 1);
        const cxi: i32 = @intFromFloat(@floor(cx));
        const cyi: i32 = @intFromFloat(@floor(cy));

        var y = cyi - bound;
        while (y <= cyi + bound) : (y += 1) {
            var x = cxi - bound;
            while (x <= cxi + bound) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const dist = @sqrt(dx * dx + dy * dy);

                var coverage = math.clamp(outer - dist + 0.5, 0.0, 1.0);
                if (inner > 0) coverage = @min(coverage, math.clamp(dist - inner + 0.5, 0.0, 1.0));
                if (coverage <= 0) continue;

                if (!full_circle) {
                    const angle = normalizeAngle(math.atan2(dy, dx));
                    const rel = normalizeAngle(angle - start);
                    if (rel > sweep_rad) continue;
                }

                canvas.set(x, y, blend(color, bg, coverage));
            }
        }
    }

    pub fn drawGlyph(canvas: Canvas, x0: i32, y0: i32, ch: u8, color: Color, scale: i32) void {
        const rows = Font.glyph(ch) orelse return;
        for (rows, 0..) |row, ry| {
            var col: usize = 0;
            while (col < Font.width) : (col += 1) {
                const bit: u3 = @intCast(Font.width - 1 - col);
                if (row & (@as(u8, 1) << bit) != 0) {
                    canvas.fillRect(
                        x0 + @as(i32, @intCast(col)) * scale,
                        y0 + @as(i32, @intCast(ry)) * scale,
                        scale,
                        scale,
                        color,
                    );
                }
            }
        }
    }

    pub fn drawText(canvas: Canvas, x0: i32, y0: i32, text: []const u8, color: Color, scale: i32) void {
        var x = x0;
        for (text) |ch| {
            canvas.drawGlyph(x, y0, ch, color, scale);
            x += (Font.width + 1) * scale;
        }
    }
};

pub fn textWidth(text: []const u8, scale: i32) i32 {
    if (text.len == 0) return 0;
    const advance = (Font.width + 1) * scale;
    return @as(i32, @intCast(text.len)) * advance - scale;
}

fn normalizeAngle(a: f32) f32 {
    var r = @mod(a, math.tau);
    if (r < 0) r += math.tau;
    return r;
}

fn channel(c: Color, shift: u5) u8 {
    return @truncate(c >> shift);
}

fn lerp8(a: u8, b: u8, t: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return @intFromFloat(fa + (fb - fa) * t);
}

pub fn blend(fg: Color, bg: Color, coverage: f32) Color {
    const t = math.clamp(coverage, 0.0, 1.0);
    const r = lerp8(channel(bg, 16), channel(fg, 16), t);
    const g = lerp8(channel(bg, 8), channel(fg, 8), t);
    const b = lerp8(channel(bg, 0), channel(fg, 0), t);
    return (@as(Color, r) << 16) | (@as(Color, g) << 8) | b;
}

const testing = std.testing;

test "blend at zero coverage returns the background untouched" {
    try testing.expectEqual(@as(Color, 0x123456), blend(0xffffff, 0x123456, 0.0));
}

test "blend at full coverage returns the foreground untouched" {
    try testing.expectEqual(@as(Color, 0xabcdef), blend(0xabcdef, 0x000000, 1.0));
}

test "blend clamps coverage outside [0, 1]" {
    try testing.expectEqual(blend(0xffffff, 0x000000, 1.0), blend(0xffffff, 0x000000, 5.0));
    try testing.expectEqual(blend(0xffffff, 0x000000, 0.0), blend(0xffffff, 0x000000, -5.0));
}

test "textWidth is zero for an empty string and grows by one advance per glyph" {
    try testing.expectEqual(@as(i32, 0), textWidth("", 2));
    const one = textWidth("A", 2);
    const two = textWidth("AA", 2);
    try testing.expectEqual(one + (Font.width + 1) * 2, two);
}
