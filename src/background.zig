const std = @import("std");
const mem = std.mem;
const math = std.math;

const zigimg = @import("zigimg");
const gfx = @import("render.zig");

pub const Mode = enum { fill, fit, stretch, center, tile };

pub const DecodedImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(image: *DecodedImage, gpa: mem.Allocator) void {
        gpa.free(image.pixels);
        image.* = undefined;
    }
};

pub fn load(gpa: mem.Allocator, io: std.Io, path: []const u8) !DecodedImage {
    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(gpa, io, path, &read_buffer);
    defer image.deinit(gpa);

    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    if (image.width > math.maxInt(u31) or image.height > math.maxInt(u31)) {
        return error.ImageTooLarge;
    }

    const w: u32 = @intCast(image.width);
    const h: u32 = @intCast(image.height);
    const pixels = try gpa.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer gpa.free(pixels);

    var it = image.iterator();
    var i: usize = 0;
    while (it.next()) |c| : (i += 1) {
        pixels[i * 4 + 0] = to8(c.r);
        pixels[i * 4 + 1] = to8(c.g);
        pixels[i * 4 + 2] = to8(c.b);
        pixels[i * 4 + 3] = to8(c.a);
    }

    return .{ .width = w, .height = h, .pixels = pixels };
}

fn to8(v: f32) u8 {
    return @intFromFloat(math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

pub fn composite(canvas: gfx.Canvas, image: DecodedImage, mode: Mode, bg: gfx.Color) void {
    if (image.width == 0 or image.height == 0) return;
    if (canvas.width == 0 or canvas.height == 0) return;

    switch (mode) {
        .tile => compositeTile(canvas, image, bg),
        else => compositeScaled(canvas, image, placement(mode, image.width, image.height, canvas.width, canvas.height), bg),
    }
}

const Placement = struct {
    dst_x: i32,
    dst_y: i32,
    dst_w: i32,
    dst_h: i32,
};

fn placement(mode: Mode, img_w: u32, img_h: u32, buf_w: u32, buf_h: u32) Placement {
    const iw: f32 = @floatFromInt(img_w);
    const ih: f32 = @floatFromInt(img_h);
    const bw: f32 = @floatFromInt(buf_w);
    const bh: f32 = @floatFromInt(buf_h);

    return switch (mode) {
        .stretch => .{
            .dst_x = 0,
            .dst_y = 0,
            .dst_w = @intCast(buf_w),
            .dst_h = @intCast(buf_h),
        },
        .center => centered(img_w, img_h, buf_w, buf_h),
        .fill => scaledCentered(iw, ih, bw, bh, @max(bw / iw, bh / ih)),
        .fit => scaledCentered(iw, ih, bw, bh, @min(bw / iw, bh / ih)),
        .tile => unreachable,
    };
}

fn centered(img_w: u32, img_h: u32, buf_w: u32, buf_h: u32) Placement {
    const dw: i32 = @intCast(img_w);
    const dh: i32 = @intCast(img_h);
    return .{
        .dst_x = @divTrunc(@as(i32, @intCast(buf_w)) - dw, 2),
        .dst_y = @divTrunc(@as(i32, @intCast(buf_h)) - dh, 2),
        .dst_w = dw,
        .dst_h = dh,
    };
}

fn scaledCentered(iw: f32, ih: f32, bw: f32, bh: f32, scale: f32) Placement {
    const dw = iw * scale;
    const dh = ih * scale;
    return .{
        .dst_x = @intFromFloat(@round((bw - dw) / 2.0)),
        .dst_y = @intFromFloat(@round((bh - dh) / 2.0)),
        .dst_w = @intFromFloat(@round(dw)),
        .dst_h = @intFromFloat(@round(dh)),
    };
}

fn compositeScaled(canvas: gfx.Canvas, image: DecodedImage, p: Placement, bg: gfx.Color) void {
    if (p.dst_w <= 0 or p.dst_h <= 0) return;

    const y0 = @max(p.dst_y, 0);
    const y1 = @min(p.dst_y + p.dst_h, @as(i32, canvas.height));
    const x0 = @max(p.dst_x, 0);
    const x1 = @min(p.dst_x + p.dst_w, @as(i32, canvas.width));

    const dst_w_f: f32 = @floatFromInt(p.dst_w);
    const dst_h_f: f32 = @floatFromInt(p.dst_h);
    const img_w_f: f32 = @floatFromInt(image.width);
    const img_h_f: f32 = @floatFromInt(image.height);

    var y = y0;
    while (y < y1) : (y += 1) {
        const v = (@as(f32, @floatFromInt(y - p.dst_y)) + 0.5) / dst_h_f;
        const sy: u32 = @intFromFloat(@min(v * img_h_f, img_h_f - 1.0));
        var x = x0;
        while (x < x1) : (x += 1) {
            const u = (@as(f32, @floatFromInt(x - p.dst_x)) + 0.5) / dst_w_f;
            const sx: u32 = @intFromFloat(@min(u * img_w_f, img_w_f - 1.0));
            putPixel(canvas, x, y, image, sx, sy, bg);
        }
    }
}

fn compositeTile(canvas: gfx.Canvas, image: DecodedImage, bg: gfx.Color) void {
    var y: i32 = 0;
    while (y < canvas.height) : (y += 1) {
        const sy: u32 = @intCast(@mod(y, @as(i32, @intCast(image.height))));
        var x: i32 = 0;
        while (x < canvas.width) : (x += 1) {
            const sx: u32 = @intCast(@mod(x, @as(i32, @intCast(image.width))));
            putPixel(canvas, x, y, image, sx, sy, bg);
        }
    }
}

fn putPixel(canvas: gfx.Canvas, x: i32, y: i32, image: DecodedImage, sx: u32, sy: u32, bg: gfx.Color) void {
    const idx = (@as(usize, sy) * image.width + sx) * 4;
    const r = image.pixels[idx + 0];
    const g = image.pixels[idx + 1];
    const b = image.pixels[idx + 2];
    const a = image.pixels[idx + 3];
    if (a == 0) return;

    const fg: gfx.Color = (@as(gfx.Color, r) << 16) | (@as(gfx.Color, g) << 8) | b;
    const px = if (a == 255) fg else gfx.blend(fg, bg, @as(f32, @floatFromInt(a)) / 255.0);

    canvas.pixels[@as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x))] = px;
}

const testing = std.testing;

test "placement: stretch always maps to the full buffer regardless of image size" {
    const p = placement(.stretch, 100, 50, 800, 600);
    try testing.expectEqual(Placement{ .dst_x = 0, .dst_y = 0, .dst_w = 800, .dst_h = 600 }, p);
}

test "placement: fill scales by the larger ratio and centers, cropping overflow" {
    const p = placement(.fill, 100, 100, 800, 600);
    try testing.expectEqual(@as(i32, 800), p.dst_w);
    try testing.expectEqual(@as(i32, 800), p.dst_h);
    try testing.expectEqual(@as(i32, 0), p.dst_x);
    try testing.expectEqual(@as(i32, -100), p.dst_y);
}

test "placement: fit scales by the smaller ratio and centers, letterboxing" {
    const p = placement(.fit, 100, 100, 800, 600);
    try testing.expectEqual(@as(i32, 600), p.dst_w);
    try testing.expectEqual(@as(i32, 600), p.dst_h);
    try testing.expectEqual(@as(i32, 100), p.dst_x);
    try testing.expectEqual(@as(i32, 0), p.dst_y);
}

test "placement: center leaves the image at native size, centered" {
    const p = placement(.center, 100, 100, 800, 600);
    try testing.expectEqual(@as(i32, 100), p.dst_w);
    try testing.expectEqual(@as(i32, 100), p.dst_h);
    try testing.expectEqual(@as(i32, 350), p.dst_x);
    try testing.expectEqual(@as(i32, 250), p.dst_y);
}

fn testImage(pixels: []u8, w: u32, h: u32) DecodedImage {
    return .{ .width = w, .height = h, .pixels = pixels };
}

test "composite: stretch fills the entire canvas with a 1x1 opaque image's color" {
    var buf: [4]u32 = undefined;
    const canvas: gfx.Canvas = .{ .pixels = &buf, .width = 2, .height = 2 };
    var px = [_]u8{ 0x11, 0x22, 0x33, 255 };
    composite(canvas, testImage(&px, 1, 1), .stretch, 0x000000);
    for (buf) |p| try testing.expectEqual(@as(u32, 0x112233), p);
}

test "composite: fully transparent pixels leave the pre-painted bg untouched" {
    var buf = [_]u32{0xAABBCC};
    const canvas: gfx.Canvas = .{ .pixels = &buf, .width = 1, .height = 1 };
    var px = [_]u8{ 0xFF, 0xFF, 0xFF, 0 };
    composite(canvas, testImage(&px, 1, 1), .stretch, 0xAABBCC);
    try testing.expectEqual(@as(u32, 0xAABBCC), buf[0]);
}

test "composite: half-alpha pixel matches gfx.blend with coverage 0.5" {
    var buf = [_]u32{0x000000};
    const canvas: gfx.Canvas = .{ .pixels = &buf, .width = 1, .height = 1 };
    var px = [_]u8{ 0xFF, 0xFF, 0xFF, 128 };
    composite(canvas, testImage(&px, 1, 1), .stretch, 0x000000);
    try testing.expectEqual(gfx.blend(0xFFFFFF, 0x000000, 128.0 / 255.0), buf[0]);
}

test "composite: tile repeats a 1x1 image across a larger canvas" {
    var buf: [4]u32 = undefined;
    const canvas: gfx.Canvas = .{ .pixels = &buf, .width = 2, .height = 2 };
    var px = [_]u8{ 0x10, 0x20, 0x30, 255 };
    composite(canvas, testImage(&px, 1, 1), .tile, 0x000000);
    for (buf) |p| try testing.expectEqual(@as(u32, 0x102030), p);
}
