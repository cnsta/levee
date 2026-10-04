const Video = @This();

const std = @import("std");
const mem = std.mem;
const math = std.math;

const c = @import("vpx");

const mp4 = @import("video/mp4.zig");
const DecodedImage = @import("background.zig").DecodedImage;

const log = std.log.scoped(.video);

gpa: mem.Allocator,
bytes: []const u8,
owns_bytes: bool,
track: mp4.Track,
codec: c.vpx_codec_ctx_t,
frame: DecodedImage,
decoded: ?usize = null,

pub fn create(gpa: mem.Allocator, bytes: []const u8, owns_bytes: bool) !*Video {
    errdefer if (owns_bytes) gpa.free(bytes);

    var track = try mp4.parse(gpa, bytes);
    errdefer track.deinit(gpa);

    const pixels = try gpa.alloc(u8, @as(usize, track.width) * track.height * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);

    const video = try gpa.create(Video);
    errdefer gpa.destroy(video);
    video.* = .{
        .gpa = gpa,
        .bytes = bytes,
        .owns_bytes = owns_bytes,
        .track = track,
        .codec = undefined,
        .frame = .{ .width = track.width, .height = track.height, .pixels = pixels, .@"opaque" = true },
    };

    const cfg: c.vpx_codec_dec_cfg_t = .{ .threads = 1, .w = 0, .h = 0 };
    const iface = switch (track.codec) {
        .vp8 => c.vpx_codec_vp8_dx(),
        .vp9 => c.vpx_codec_vp9_dx(),
    };
    if (c.vpx_codec_dec_init_ver(&video.codec, iface, &cfg, 0, c.VPX_DECODER_ABI_VERSION) != c.VPX_CODEC_OK) {
        log.err("failed to initialize the {s} decoder", .{@tagName(track.codec)});
        return error.DecoderInit;
    }
    errdefer _ = c.vpx_codec_destroy(&video.codec);

    try video.decode(0);
    return video;
}

pub fn destroy(video: *Video) void {
    const gpa = video.gpa;
    _ = c.vpx_codec_destroy(&video.codec);
    gpa.free(video.frame.pixels);
    video.track.deinit(gpa);
    if (video.owns_bytes) gpa.free(video.bytes);
    gpa.destroy(video);
}

pub fn frameCount(video: *const Video) usize {
    return video.track.samples.len;
}

pub fn delayMs(video: *const Video, index: usize) u32 {
    return video.track.samples[index].delay_ms;
}

pub fn decode(video: *Video, index: usize) !void {
    var next: usize = if (video.decoded) |d| d + 1 else 0;
    if (index < next) next = 0;
    while (next <= index) : (next += 1) {
        try video.feed(next, next == index);
        video.decoded = next;
    }
}

fn feed(video: *Video, index: usize, convert: bool) !void {
    const data = video.track.sampleBytes(video.bytes, index);
    if (c.vpx_codec_decode(&video.codec, data.ptr, @intCast(data.len), null, 0) != c.VPX_CODEC_OK) {
        log.err("failed to decode frame {d}: {s}", .{ index, mem.sliceTo(c.vpx_codec_error(&video.codec), 0) });
        return error.DecodeFailed;
    }

    var iter: c.vpx_codec_iter_t = null;
    var shown: ?*c.vpx_image_t = null;
    while (c.vpx_codec_get_frame(&video.codec, &iter)) |img| shown = img;
    const img = shown orelse return;
    if (!convert) return;

    if (img.fmt != c.VPX_IMG_FMT_I420 or img.bit_depth != 8) return error.UnsupportedPixelFormat;
    if (img.d_w != video.frame.width or img.d_h != video.frame.height) {
        const pixels = try video.gpa.realloc(video.frame.pixels, @as(usize, img.d_w) * img.d_h * 4);
        video.frame = .{ .width = img.d_w, .height = img.d_h, .pixels = pixels, .@"opaque" = true };
    }

    const matrix = Matrix.pick(img.cs, img.range, img.d_h);
    i420ToRgba(
        .{ img.planes[0], img.planes[1], img.planes[2] },
        .{ @intCast(img.stride[0]), @intCast(img.stride[1]), @intCast(img.stride[2]) },
        video.frame,
        matrix,
    );
}

pub const Matrix = struct {
    y_offset: i16,
    y_max: i16,
    c_max: i16,
    y_scale: i16,
    rv: i16,
    gu: i16,
    gv: i16,
    bu: i16,

    const V = @Vector(lanes, i16);

    fn fixed(v: f64) i16 {
        return @intFromFloat(@round(v * 128.0));
    }

    fn init(kr: f64, kb: f64, full: bool) Matrix {
        const kg = 1.0 - kr - kb;
        const ys: f64 = if (full) 1.0 else 255.0 / 219.0;
        const cs: f64 = if (full) 1.0 else 255.0 / 224.0;
        return .{
            .y_offset = if (full) 0 else 16,
            .y_max = if (full) 255 else 219,
            .c_max = if (full) 127 else 112,
            .y_scale = fixed(ys),
            .rv = fixed(2.0 * (1.0 - kr) * cs),
            .gu = fixed(-2.0 * (1.0 - kb) * kb / kg * cs),
            .gv = fixed(-2.0 * (1.0 - kr) * kr / kg * cs),
            .bu = fixed(2.0 * (1.0 - kb) * cs),
        };
    }

    pub fn pick(cs: c.vpx_color_space_t, range: c.vpx_color_range_t, height: u32) Matrix {
        const full = range == c.VPX_CR_FULL_RANGE;
        return switch (cs) {
            c.VPX_CS_BT_601, c.VPX_CS_SMPTE_170 => init(0.299, 0.114, full),
            c.VPX_CS_BT_709 => init(0.2126, 0.0722, full),
            c.VPX_CS_BT_2020 => init(0.2627, 0.0593, full),
            else => if (height >= 720) init(0.2126, 0.0722, full) else init(0.299, 0.114, full),
        };
    }

    fn toRgba(m: Matrix, y: [lanes]u8, u: [lanes / 2]u8, v: [lanes / 2]u8) [lanes]u32 {
        const widen = comptime blk: {
            var mask: [lanes]i32 = undefined;
            for (&mask, 0..) |*e, i| e.* = @intCast(i / 2);
            break :blk mask;
        };
        const uh: @Vector(lanes / 2, u8) = u;
        const vh: @Vector(lanes / 2, u8) = v;
        const yv: @Vector(lanes, u8) = y;

        const c_max: V = @splat(m.c_max);
        const uu = @min(@max(@as(V, @shuffle(u8, uh, undefined, widen)) - splat(128), -c_max), c_max);
        const vv = @min(@max(@as(V, @shuffle(u8, vh, undefined, widen)) - splat(128), -c_max), c_max);
        const yy = @min(@max(@as(V, yv) - splat(m.y_offset), splat(-m.y_offset)), splat(m.y_max)) *
            splat(m.y_scale) +| splat(64);

        const r = clamp8(yy +| splat(m.rv) * vv);
        const g = clamp8(yy +| splat(m.gu) * uu +| splat(m.gv) * vv);
        const b = clamp8(yy +| splat(m.bu) * uu);
        const U = @Vector(lanes, u32);
        return r | (g << @splat(8)) | (b << @splat(16)) | @as(U, @splat(0xff00_0000));
    }

    pub fn toRgb(m: Matrix, y: u8, u: u8, v: u8) [3]u8 {
        const word = m.toRgba(@splat(y), @splat(u), @splat(v))[0];
        return .{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16) };
    }

    fn splat(x: i16) V {
        return @splat(x);
    }

    fn clamp8(q7: V) @Vector(lanes, u32) {
        return @intCast(@min(@max(q7 >> @splat(7), splat(0)), splat(255)));
    }
};

const lanes = 16;

fn i420ToRgba(planes: [3][*c]const u8, strides: [3]usize, dst: DecodedImage, m: Matrix) void {
    for (0..dst.height) |row| {
        const y_row = planes[0] + row * strides[0];
        const u_row = planes[1] + (row / 2) * strides[1];
        const v_row = planes[2] + (row / 2) * strides[2];
        const out = dst.pixels[row * dst.width * 4 ..][0 .. dst.width * 4];

        var col: usize = 0;
        while (col + lanes <= dst.width) : (col += lanes) {
            const rgba = m.toRgba(y_row[col..][0..lanes].*, u_row[col / 2 ..][0 .. lanes / 2].*, v_row[col / 2 ..][0 .. lanes / 2].*);
            out[col * 4 ..][0 .. lanes * 4].* = @bitCast(rgba);
        }
        if (col == dst.width) continue;

        const n = dst.width - col;
        var y: [lanes]u8 = @splat(0);
        var u: [lanes / 2]u8 = @splat(128);
        var v: [lanes / 2]u8 = @splat(128);
        @memcpy(y[0..n], y_row[col..][0..n]);
        @memcpy(u[0 .. (n + 1) / 2], u_row[col / 2 ..][0 .. (n + 1) / 2]);
        @memcpy(v[0 .. (n + 1) / 2], v_row[col / 2 ..][0 .. (n + 1) / 2]);
        const rgba: [lanes * 4]u8 = @bitCast(m.toRgba(y, u, v));
        @memcpy(out[col * 4 ..], rgba[0 .. n * 4]);
    }
}

const testing = std.testing;

const sample_video = @embedFile("assets/wallpaper.mp4");

test "decodes the bundled wallpaper: real pixels, frames change, loops back to 0" {
    const video = try create(testing.allocator, sample_video, false);
    defer video.destroy();

    try testing.expectEqual(@as(u32, 1920), video.frame.width);
    try testing.expectEqual(@as(u32, 1080), video.frame.height);

    const first = try testing.allocator.dupe(u8, video.frame.pixels);
    defer testing.allocator.free(first);
    try testing.expect(mem.indexOfNone(u8, first, &.{ 0, 255 }) != null);

    try video.decode(1);
    try video.decode(2);
    try testing.expect(!mem.eql(u8, first, video.frame.pixels));

    try video.decode(0);
    try testing.expectEqualSlices(u8, first, video.frame.pixels);
}

test "create rejects garbage without leaking" {
    try testing.expectError(error.Malformed, create(testing.allocator, "\x00\x00\x00\x08ftyp", false));
    const owned = try testing.allocator.dupe(u8, "\x00\x00\x00\x08ftyp");
    try testing.expectError(error.Malformed, create(testing.allocator, owned, true));
}

test "Matrix: limited-range black, white and grey, full-range passthrough" {
    const bt709 = Matrix.init(0.2126, 0.0722, false);
    try testing.expectEqual([3]u8{ 0, 0, 0 }, bt709.toRgb(16, 128, 128));
    try testing.expectEqual([3]u8{ 255, 255, 255 }, bt709.toRgb(235, 128, 128));
    try testing.expectEqual([3]u8{ 128, 128, 128 }, bt709.toRgb(126, 128, 128));

    const full = Matrix.init(0.2126, 0.0722, true);
    try testing.expectEqual([3]u8{ 77, 77, 77 }, full.toRgb(77, 128, 128));
}

test "Matrix: BT.709 limited-range pure red round-trips" {
    // studio-swing BT.709 encoding of (255, 0, 0).
    const rgb = Matrix.init(0.2126, 0.0722, false).toRgb(63, 102, 240);
    try testing.expect(rgb[0] >= 253);
    try testing.expect(rgb[1] <= 2);
    try testing.expect(rgb[2] <= 2);
}

test "i420ToRgba: an odd-width tail converts like the vector body" {
    const w = lanes + 3;
    var y: [w * 2]u8 = undefined;
    for (&y, 0..) |*e, i| e.* = @intCast(16 + i * 7 % 220);
    var u: [(w + 1) / 2]u8 = undefined;
    var v: [(w + 1) / 2]u8 = undefined;
    for (&u, &v, 0..) |*a, *b, i| {
        a.* = @intCast(40 + i * 13);
        b.* = @intCast(200 - i * 11);
    }
    var pixels: [w * 2 * 4]u8 = undefined;
    const m = Matrix.init(0.2126, 0.0722, false);
    i420ToRgba(.{ &y, &u, &v }, .{ w, 0, 0 }, .{ .width = w, .height = 2, .pixels = &pixels }, m);

    for (0..2) |row| for (0..w) |col| {
        const rgb = m.toRgb(y[row * w + col], u[col / 2], v[col / 2]);
        try testing.expectEqualSlices(u8, &.{ rgb[0], rgb[1], rgb[2], 255 }, pixels[(row * w + col) * 4 ..][0..4]);
    };
}
