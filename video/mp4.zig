const std = @import("std");
const mem = std.mem;
const math = std.math;

pub const Codec = enum { vp8, vp9 };

pub const Sample = struct {
    offset: usize,
    size: u32,
    delay_ms: u32,
};

pub const Track = struct {
    codec: Codec,
    width: u16,
    height: u16,
    samples: []Sample,

    pub fn deinit(track: *Track, gpa: mem.Allocator) void {
        gpa.free(track.samples);
        track.* = undefined;
    }

    pub fn sampleBytes(track: Track, bytes: []const u8, index: usize) []const u8 {
        const s = track.samples[index];
        return bytes[s.offset..][0..s.size];
    }
};

pub const Error = error{
    Malformed,
    NoVideoTrack,
    UnsupportedCodec,
    OutOfMemory,
};

pub fn sniff(bytes: []const u8) bool {
    return bytes.len >= 8 and mem.eql(u8, bytes[4..8], "ftyp");
}

pub fn parse(gpa: mem.Allocator, bytes: []const u8) Error!Track {
    const moov = try findChild(bytes, "moov") orelse return error.Malformed;

    var it: BoxIterator = .{ .data = moov };
    while (try it.next()) |box| {
        if (!mem.eql(u8, &box.kind, "trak")) continue;
        const mdia = try findChild(box.body, "mdia") orelse continue;
        const hdlr = try findChild(mdia, "hdlr") orelse continue;
        if (hdlr.len < 12 or !mem.eql(u8, hdlr[8..12], "vide")) continue;
        return parseVideoTrak(gpa, bytes, mdia);
    }
    return error.NoVideoTrack;
}

fn parseVideoTrak(gpa: mem.Allocator, file: []const u8, mdia: []const u8) Error!Track {
    const mdhd = try findChild(mdia, "mdhd") orelse return error.Malformed;
    const timescale = try readTimescale(mdhd);

    const minf = try findChild(mdia, "minf") orelse return error.Malformed;
    const stbl = try findChild(minf, "stbl") orelse return error.Malformed;

    const entry = try readSampleEntry(try findChild(stbl, "stsd") orelse return error.Malformed);

    const stsz = try findChild(stbl, "stsz") orelse return error.Malformed;
    if (stsz.len < 12) return error.Malformed;
    const fixed_size = readInt(u32, stsz, 4);
    const count = readInt(u32, stsz, 8);
    if (count == 0) return error.Malformed;
    if (count > file.len) return error.Malformed;
    if (fixed_size == 0 and (stsz.len - 12) / 4 < count) return error.Malformed;

    const samples = try gpa.alloc(Sample, count);
    errdefer gpa.free(samples);

    for (samples, 0..) |*s, i| {
        const size = if (fixed_size != 0) fixed_size else readInt(u32, stsz, 12 + i * 4);
        if (size == 0) return error.Malformed;
        s.* = .{ .offset = 0, .size = size, .delay_ms = 0 };
    }

    try fillDelays(samples, try findChild(stbl, "stts") orelse return error.Malformed, timescale);
    try fillOffsets(samples, file, stbl);

    return .{ .codec = entry.codec, .width = entry.width, .height = entry.height, .samples = samples };
}

fn readTimescale(mdhd: []const u8) Error!u32 {
    if (mdhd.len < 4) return error.Malformed;
    const at: usize = switch (mdhd[0]) {
        0 => 12,
        1 => 20,
        else => return error.Malformed,
    };
    if (mdhd.len < at + 4) return error.Malformed;
    const timescale = readInt(u32, mdhd, at);
    if (timescale == 0) return error.Malformed;
    return timescale;
}

const SampleEntry = struct { codec: Codec, width: u16, height: u16 };

fn readSampleEntry(stsd: []const u8) Error!SampleEntry {
    if (stsd.len < 8) return error.Malformed;
    if (readInt(u32, stsd, 4) == 0) return error.Malformed;

    var it: BoxIterator = .{ .data = stsd[8..] };
    const box = try it.next() orelse return error.Malformed;
    const codec: Codec = if (mem.eql(u8, &box.kind, "vp09"))
        .vp9
    else if (mem.eql(u8, &box.kind, "vp08"))
        .vp8
    else
        return error.UnsupportedCodec;

    if (box.body.len < 28) return error.Malformed;
    const width = readInt(u16, box.body, 24);
    const height = readInt(u16, box.body, 26);
    if (width == 0 or height == 0) return error.Malformed;
    return .{ .codec = codec, .width = width, .height = height };
}

fn fillDelays(samples: []Sample, stts: []const u8, timescale: u32) Error!void {
    if (stts.len < 8) return error.Malformed;
    const entries = readInt(u32, stts, 4);
    if (entries == 0 or (stts.len - 8) / 8 < entries) return error.Malformed;

    var i: usize = 0;
    var last_delay: u32 = 0;
    for (0..entries) |e| {
        const n = readInt(u32, stts, 8 + e * 8);
        last_delay = deltaToMs(readInt(u32, stts, 8 + e * 8 + 4), timescale);
        const end = @min(samples.len, i +| n);
        for (samples[i..end]) |*s| s.delay_ms = last_delay;
        i = end;
    }
    for (samples[i..]) |*s| s.delay_ms = last_delay;
}

fn deltaToMs(delta: u32, timescale: u32) u32 {
    const ms = (@as(u64, delta) * 1000 + timescale / 2) / timescale;
    return @intCast(math.clamp(ms, 1, 3_600_000));
}

fn fillOffsets(samples: []Sample, file: []const u8, stbl: []const u8) Error!void {
    const stsc = try findChild(stbl, "stsc") orelse return error.Malformed;
    if (stsc.len < 8) return error.Malformed;
    const runs = readInt(u32, stsc, 4);
    if (runs == 0 or (stsc.len - 8) / 12 < runs) return error.Malformed;

    var wide = false;
    const chunk_box = if (try findChild(stbl, "stco")) |b| b else if (try findChild(stbl, "co64")) |b| blk: {
        wide = true;
        break :blk b;
    } else return error.Malformed;
    if (chunk_box.len < 8) return error.Malformed;
    const chunks = readInt(u32, chunk_box, 4);
    const entry_size: usize = if (wide) 8 else 4;
    if ((chunk_box.len - 8) / entry_size < chunks) return error.Malformed;

    var sample: usize = 0;
    var run: usize = 0;
    var chunk: u32 = 0;
    while (chunk < chunks and sample < samples.len) : (chunk += 1) {
        while (run + 1 < runs and readInt(u32, stsc, 8 + (run + 1) * 12) <= chunk + 1) run += 1;
        const per_chunk = readInt(u32, stsc, 8 + run * 12 + 4);

        var offset: u64 = if (wide)
            readInt(u64, chunk_box, 8 + @as(usize, chunk) * 8)
        else
            readInt(u32, chunk_box, 8 + @as(usize, chunk) * 4);

        var k: u32 = 0;
        while (k < per_chunk and sample < samples.len) : (k += 1) {
            const s = &samples[sample];
            if (offset > file.len or file.len - offset < s.size) return error.Malformed;
            s.offset = @intCast(offset);
            offset += s.size;
            sample += 1;
        }
    }
    if (sample != samples.len) return error.Malformed;
}

const Box = struct {
    kind: [4]u8,
    body: []const u8,
};

const BoxIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(it: *BoxIterator) Error!?Box {
        if (it.pos == it.data.len) return null;
        const rest = it.data[it.pos..];
        if (rest.len < 8) return error.Malformed;

        var header: usize = 8;
        var size: u64 = readInt(u32, rest, 0);
        if (size == 1) {
            if (rest.len < 16) return error.Malformed;
            size = readInt(u64, rest, 8);
            header = 16;
        } else if (size == 0) {
            size = rest.len;
        }
        if (size < header or size > rest.len) return error.Malformed;

        it.pos += @intCast(size);
        return .{ .kind = rest[4..8].*, .body = rest[header..@intCast(size)] };
    }
};

fn findChild(data: []const u8, comptime kind: *const [4]u8) Error!?[]const u8 {
    var it: BoxIterator = .{ .data = data };
    while (try it.next()) |box| {
        if (mem.eql(u8, &box.kind, kind)) return box.body;
    }
    return null;
}

fn readInt(comptime T: type, data: []const u8, at: usize) T {
    return mem.readInt(T, data[at..][0..@sizeOf(T)], .big);
}

const testing = std.testing;

const sample_video = @embedFile("../assets/wallpaper.mp4");

test "parse: the bundled wallpaper is a 720-frame 1080p VP9 track of about 24 s" {
    var track = try parse(testing.allocator, sample_video);
    defer track.deinit(testing.allocator);

    try testing.expectEqual(Codec.vp9, track.codec);
    try testing.expectEqual(@as(u16, 1920), track.width);
    try testing.expectEqual(@as(u16, 1080), track.height);
    try testing.expectEqual(@as(usize, 720), track.samples.len);

    var total: u64 = 0;
    for (track.samples) |s| {
        try testing.expect(s.offset + s.size <= sample_video.len);
        try testing.expect(s.delay_ms >= 33 and s.delay_ms <= 34);
        total += s.delay_ms;
    }
    try testing.expect(total >= 23_500 and total <= 24_500);
    try testing.expect(track.samples[1].offset >= track.samples[0].offset + track.samples[0].size);
}

test "sniff: only ftyp-led files count" {
    try testing.expect(sniff(sample_video));
    try testing.expect(!sniff("GIF89a\x00\x00"));
    try testing.expect(!sniff("ftyp"));
}

test "parse: every truncation of the file is an error, not a crash" {
    var len: usize = 0;
    while (len < sample_video.len) : (len += sample_video.len / 97 + 1) {
        if (parse(testing.allocator, sample_video[0..len])) |t| {
            var track = t;
            track.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "parse: a box claiming more bytes than exist is rejected" {
    const bad = "\x00\x00\x00\x10ftypisom\x7f\xff\xff\xffmoov";
    try testing.expectError(error.Malformed, parse(testing.allocator, bad));
}

test "parse: a non-VP8/VP9 sample entry is UnsupportedCodec" {
    const copy = try testing.allocator.dupe(u8, sample_video);
    defer testing.allocator.free(copy);
    const at = mem.indexOf(u8, copy, "vp09").?;
    @memcpy(copy[at..][0..4], "avc1");
    try testing.expectError(error.UnsupportedCodec, parse(testing.allocator, copy));
}

test "deltaToMs rounds and never returns zero" {
    try testing.expectEqual(@as(u32, 33), deltaToMs(512, 15360));
    try testing.expectEqual(@as(u32, 17), deltaToMs(1001, 60000));
    try testing.expectEqual(@as(u32, 1), deltaToMs(0, 90000));
}
