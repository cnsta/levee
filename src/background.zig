const std = @import("std");
const mem = std.mem;
const math = std.math;

const zigimg = @import("zigimg");
const gfx = @import("render.zig");
const Video = @import("video.zig");
const mp4 = @import("video/mp4.zig");

const log = std.log.scoped(.background);

pub const Mode = enum { fill, fit, stretch, center, tile };

pub const DecodedImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    @"opaque": bool = false,

    pub fn deinit(image: *DecodedImage, gpa: mem.Allocator) void {
        gpa.free(image.pixels);
        image.* = undefined;
    }
};

pub const Background = struct {
    source: Source,
    loop_count: i32,

    pub const Source = union(enum) {
        frames: Frames,
        video: *Video,
    };

    pub const Frames = struct {
        images: []DecodedImage,
        delays_ms: []u32,
    };

    pub fn deinit(bg: *Background, gpa: mem.Allocator) void {
        switch (bg.source) {
            .frames => |f| {
                for (f.images) |*image| image.deinit(gpa);
                gpa.free(f.images);
                gpa.free(f.delays_ms);
            },
            .video => |v| v.destroy(),
        }
        bg.* = undefined;
    }

    pub fn frameCount(bg: Background) usize {
        return switch (bg.source) {
            .frames => |f| f.images.len,
            .video => |v| v.frameCount(),
        };
    }

    pub fn delayMs(bg: Background, index: usize) u32 {
        return switch (bg.source) {
            .frames => |f| f.delays_ms[index],
            .video => |v| v.delayMs(index),
        };
    }

    pub fn isAnimated(bg: Background) bool {
        return bg.frameCount() > 1;
    }

    pub fn current(bg: Background, index: usize) DecodedImage {
        return switch (bg.source) {
            .frames => |f| f.images[index],
            .video => |v| v.frame,
        };
    }

    pub fn show(bg: Background, index: usize) !void {
        switch (bg.source) {
            .frames => {},
            .video => |v| try v.decode(index),
        }
    }
};

pub const max_decoded_bytes: usize = 256 * 1024 * 1024;

const min_delay_ms: u32 = 20;
const fallback_delay_ms: u32 = 100;

pub fn clampDelay(seconds: f32) u32 {
    if (!(seconds > 0)) return fallback_delay_ms;
    const ms: u32 = @intFromFloat(@min(@round(seconds * 1000.0), 3_600_000.0));
    return if (ms < min_delay_ms) fallback_delay_ms else ms;
}

pub const Playback = struct {
    index: usize = 0,
    loops_done: u32 = 0,
    due_ms: i64 = 0,
    finished: bool = true,

    pub fn init(bg: Background, now_ms: i64) Playback {
        return .{
            .due_ms = now_ms + bg.delayMs(0),
            .finished = !bg.isAnimated(),
        };
    }

    pub fn timeoutMs(p: Playback, now_ms: i64) ?i32 {
        if (p.finished) return null;
        return @intCast(math.clamp(p.due_ms - now_ms, 0, math.maxInt(i32)));
    }

    pub fn advance(p: *Playback, bg: Background, now_ms: i64) bool {
        if (p.finished or now_ms < p.due_ms) return false;

        var next = p.index + 1;
        if (next == bg.frameCount()) {
            if (bg.loop_count >= 0 and p.loops_done >= bg.loop_count) {
                p.finished = true;
                return false;
            }
            p.loops_done += 1;
            next = 0;
        }

        p.index = next;
        p.due_ms = now_ms + bg.delayMs(next);
        return true;
    }
};

pub const max_file_bytes: usize = 512 * 1024 * 1024;

pub fn load(gpa: mem.Allocator, io: std.Io, path: []const u8) !Background {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    if (mp4.sniff(bytes)) return fromVideo(gpa, bytes, true);
    defer gpa.free(bytes);
    return loadImage(gpa, bytes);
}

const default_wallpaper_bytes = @embedFile("assets/wallpaper.mp4");

pub fn loadDefault(gpa: mem.Allocator) !Background {
    return fromVideo(gpa, default_wallpaper_bytes, false);
}

fn fromVideo(gpa: mem.Allocator, bytes: []const u8, owned: bool) !Background {
    return .{ .source = .{ .video = try Video.create(gpa, bytes, owned) }, .loop_count = -1 };
}

fn loadImage(gpa: mem.Allocator, bytes: []const u8) !Background {
    var image = try zigimg.Image.fromMemory(gpa, bytes);
    defer image.deinit(gpa);
    return fromImage(gpa, image);
}

fn fromImage(gpa: mem.Allocator, image: zigimg.Image) !Background {
    if (image.width == 0 or image.height == 0) return error.EmptyImage;
    if (image.width > math.maxInt(u31) or image.height > math.maxInt(u31)) {
        return error.ImageTooLarge;
    }

    const w: u32 = @intCast(image.width);
    const h: u32 = @intCast(image.height);

    var count: usize = if (image.isAnimation()) image.animation.frames.items.len else 1;
    const frame_bytes = @as(usize, w) * @as(usize, h) * 4;
    if (count > 1 and count *| frame_bytes > max_decoded_bytes) {
        log.warn(
            "animation has {d} frames of {d}x{d}, over the {d} MiB decode budget; showing only the first frame",
            .{ count, w, h, max_decoded_bytes / (1024 * 1024) },
        );
        count = 1;
    }

    const frames = try gpa.alloc(DecodedImage, count);
    var made: usize = 0;
    errdefer {
        for (frames[0..made]) |*frame| frame.deinit(gpa);
        gpa.free(frames);
    }
    const delays = try gpa.alloc(u32, count);
    errdefer gpa.free(delays);

    if (image.isAnimation()) {
        for (image.animation.frames.items[0..count], 0..) |frame, i| {
            frames[i] = try normalize(gpa, w, h, &frame.pixels);
            made += 1;
            delays[i] = clampDelay(frame.duration);
        }
    } else {
        frames[0] = try normalize(gpa, w, h, &image.pixels);
        made += 1;
        delays[0] = fallback_delay_ms;
    }

    return .{
        .source = .{ .frames = .{ .images = frames, .delays_ms = delays } },
        .loop_count = image.animation.loop_count,
    };
}

fn normalize(gpa: mem.Allocator, w: u32, h: u32, storage: *const zigimg.color.PixelStorage) !DecodedImage {
    const total = @as(usize, w) * @as(usize, h);
    if (storage.len() < total) return error.TruncatedFrame;

    const pixels = try gpa.alloc(u8, total * 4);
    errdefer gpa.free(pixels);

    var it = zigimg.color.PixelStorageIterator.init(storage);
    var i: usize = 0;
    var all_opaque = true;
    while (it.next()) |c| : (i += 1) {
        if (i == total) break;
        pixels[i * 4 + 0] = to8(c.r);
        pixels[i * 4 + 1] = to8(c.g);
        pixels[i * 4 + 2] = to8(c.b);
        pixels[i * 4 + 3] = to8(c.a);
        all_opaque = all_opaque and pixels[i * 4 + 3] == 255;
    }

    return .{ .width = w, .height = h, .pixels = pixels, .@"opaque" = all_opaque };
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

    var columns_buf: [max_columns]u32 = undefined;
    const span: usize = @intCast(@max(x1 - x0, 0));
    const columns: ?[]u32 = if (span <= max_columns) columns_buf[0..span] else null;
    if (columns) |cols| for (cols, 0..) |*sx_out, i| {
        const x: i32 = x0 + @as(i32, @intCast(i));
        const u = (@as(f32, @floatFromInt(x - p.dst_x)) + 0.5) / dst_w_f;
        sx_out.* = @intFromFloat(@min(u * img_w_f, img_w_f - 1.0));
    };

    var prev_sy: ?u32 = null;
    var y = y0;
    while (y < y1) : (y += 1) {
        const v = (@as(f32, @floatFromInt(y - p.dst_y)) + 0.5) / dst_h_f;
        const sy: u32 = @intFromFloat(@min(v * img_h_f, img_h_f - 1.0));
        if (image.@"opaque") if (columns) |cols| {
            const row = canvas.pixels[@as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x0)) ..][0..cols.len];
            if (prev_sy == sy) {
                @memcpy(row, (row.ptr - canvas.width)[0..cols.len]);
            } else {
                const src = image.pixels[@as(usize, sy) * image.width * 4 ..];
                for (row, cols) |*px, sx| {
                    const s = src[@as(usize, sx) * 4 ..][0..3];
                    px.* = (@as(u32, s[0]) << 16) | (@as(u32, s[1]) << 8) | s[2];
                }
            }
            prev_sy = sy;
            continue;
        };
        var x = x0;
        while (x < x1) : (x += 1) {
            const sx: u32 = if (columns) |cols| cols[@intCast(x - x0)] else blk: {
                const u = (@as(f32, @floatFromInt(x - p.dst_x)) + 0.5) / dst_w_f;
                break :blk @intFromFloat(@min(u * img_w_f, img_w_f - 1.0));
            };
            putPixel(canvas, x, y, image, sx, sy, bg);
        }
    }
}

const max_columns = 8192;

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

test "the bundled GIF decodes into sane RGBA8 frames" {
    var bg = try loadImage(testing.allocator, @embedFile("assets/wallpaper.gif"));
    defer bg.deinit(testing.allocator);

    try testing.expect(bg.isAnimated());
    const f = bg.source.frames;
    try testing.expectEqual(f.images.len, f.delays_ms.len);

    const first = f.images[0];
    try testing.expect(first.width > 0);
    try testing.expect(first.height > 0);

    for (f.images, f.delays_ms) |frame, delay| {
        try testing.expectEqual(first.width, frame.width);
        try testing.expectEqual(first.height, frame.height);
        try testing.expectEqual(@as(usize, frame.width) * frame.height * 4, frame.pixels.len);
        try testing.expect(delay >= min_delay_ms);
    }

    try testing.expect(!mem.eql(u8, f.images[0].pixels, f.images[1].pixels));
}

test "loadDefault plays the bundled video forever, one frame at a time" {
    var bg = try loadDefault(testing.allocator);
    defer bg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 720), bg.frameCount());
    try testing.expectEqual(@as(i32, -1), bg.loop_count);
    try testing.expectEqual(@as(u32, 1920), bg.current(0).width);

    var p = Playback.init(bg, 0);
    try testing.expectEqual(@as(?i32, 33), p.timeoutMs(0));
    try testing.expect(p.advance(bg, 40));
    try bg.show(p.index);
    try testing.expectEqual(@as(usize, 1), p.index);
}

test "clampDelay treats zero and tiny GIF delays as 100ms" {
    try testing.expectEqual(@as(u32, 100), clampDelay(0.0));
    try testing.expectEqual(@as(u32, 100), clampDelay(0.01));
    try testing.expectEqual(@as(u32, 100), clampDelay(-1.0));
    try testing.expectEqual(@as(u32, 100), clampDelay(std.math.nan(f32)));
    try testing.expectEqual(@as(u32, 20), clampDelay(0.02));
    try testing.expectEqual(@as(u32, 600), clampDelay(0.6));
}

fn testBackground(frames: []DecodedImage, delays: []u32, loop_count: i32) Background {
    return .{ .source = .{ .frames = .{ .images = frames, .delays_ms = delays } }, .loop_count = loop_count };
}

test "Playback: a single frame never schedules anything" {
    var px = [_]u8{ 0, 0, 0, 255 };
    var frames = [_]DecodedImage{testImage(&px, 1, 1)};
    var delays = [_]u32{100};
    const bg = testBackground(&frames, &delays, -1);

    var p = Playback.init(bg, 0);
    try testing.expectEqual(@as(?i32, null), p.timeoutMs(0));
    try testing.expect(!p.advance(bg, 10_000));
    try testing.expectEqual(@as(usize, 0), p.index);
}

test "Playback: advances only once the delay has elapsed, then wraps forever" {
    var px = [_]u8{ 0, 0, 0, 255 };
    var frames = [_]DecodedImage{ testImage(&px, 1, 1), testImage(&px, 1, 1) };
    var delays = [_]u32{ 100, 300 };
    const bg = testBackground(&frames, &delays, -1);

    var p = Playback.init(bg, 1000);
    try testing.expectEqual(@as(?i32, 100), p.timeoutMs(1000));
    try testing.expectEqual(@as(?i32, 40), p.timeoutMs(1060));
    try testing.expect(!p.advance(bg, 1099));

    try testing.expect(p.advance(bg, 1100));
    try testing.expectEqual(@as(usize, 1), p.index);
    try testing.expectEqual(@as(?i32, 300), p.timeoutMs(1100));

    try testing.expect(p.advance(bg, 1400));
    try testing.expectEqual(@as(usize, 0), p.index);
    try testing.expect(!p.finished);
}

test "Playback: a late wakeup shows one new frame, not the whole backlog" {
    var px = [_]u8{ 0, 0, 0, 255 };
    var frames = [_]DecodedImage{ testImage(&px, 1, 1), testImage(&px, 1, 1), testImage(&px, 1, 1) };
    var delays = [_]u32{ 100, 100, 100 };
    const bg = testBackground(&frames, &delays, -1);

    var p = Playback.init(bg, 0);
    try testing.expect(p.advance(bg, 60_000));
    try testing.expectEqual(@as(usize, 1), p.index);
    try testing.expectEqual(@as(?i32, 100), p.timeoutMs(60_000));
}

test "Playback: a finite loop count holds the last frame" {
    var px = [_]u8{ 0, 0, 0, 255 };
    var frames = [_]DecodedImage{ testImage(&px, 1, 1), testImage(&px, 1, 1) };
    var delays = [_]u32{ 100, 100 };

    // 0 = play once.
    var once = Playback.init(testBackground(&frames, &delays, 0), 0);
    const bg_once = testBackground(&frames, &delays, 0);
    try testing.expect(once.advance(bg_once, 100));
    try testing.expect(!once.advance(bg_once, 200));
    try testing.expect(once.finished);
    try testing.expectEqual(@as(usize, 1), once.index);
    try testing.expectEqual(@as(?i32, null), once.timeoutMs(200));

    // 1 = one repeat, two plays in total.
    const bg_twice = testBackground(&frames, &delays, 1);
    var twice = Playback.init(bg_twice, 0);
    try testing.expect(twice.advance(bg_twice, 100)); // -> frame 1
    try testing.expect(twice.advance(bg_twice, 200)); // wraps to frame 0
    try testing.expectEqual(@as(usize, 0), twice.index);
    try testing.expect(twice.advance(bg_twice, 300)); // -> frame 1
    try testing.expect(!twice.advance(bg_twice, 400)); // out of loops
    try testing.expect(twice.finished);
}

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

test "composite: the opaque fast path draws exactly what the general path draws" {
    var px: [3 * 2 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = if (i % 4 == 3) 255 else @intCast(i * 37 % 256);

    for ([_]Mode{ .fill, .fit, .stretch, .center }) |mode| {
        var slow: [7 * 5]u32 = @splat(0x010203);
        var fast: [7 * 5]u32 = @splat(0x010203);
        var image = testImage(&px, 3, 2);
        composite(.{ .pixels = &slow, .width = 7, .height = 5 }, image, mode, 0x010203);
        image.@"opaque" = true;
        composite(.{ .pixels = &fast, .width = 7, .height = 5 }, image, mode, 0x010203);
        try testing.expectEqualSlices(u32, &slow, &fast);
    }
}
