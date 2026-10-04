const std = @import("std");
const math = std.math;

pub const Fade = struct {
    delay_ms: u32,
    duration_ms: u32,
    start_ms: ?i64 = null,

    pub const tick_ms = 33;

    pub fn init(duration_s: u32, end_s: u32) ?Fade {
        const duration = @min(duration_s, end_s);
        if (duration == 0) return null;
        return .{
            .delay_ms = toMs(end_s - duration),
            .duration_ms = toMs(duration),
        };
    }

    fn toMs(s: u32) u32 {
        return math.mul(u32, s, 1000) catch math.maxInt(u32);
    }

    pub fn alpha(f: Fade, now_ms: i64) f32 {
        const start = f.start_ms orelse return 0;
        const elapsed: f32 = @floatFromInt(@max(0, now_ms - start));
        return @min(1, elapsed / @as(f32, @floatFromInt(f.duration_ms)));
    }

    pub fn timeoutMs(f: Fade, now_ms: i64) ?i32 {
        if (f.start_ms == null or f.alpha(now_ms) >= 1) return null;
        return tick_ms;
    }
};

const testing = std.testing;

test "Fade.init: ends at end_s, shortened when end_s is shorter" {
    const long = Fade.init(20, 60).?;
    try testing.expectEqual(@as(u32, 40_000), long.delay_ms);
    try testing.expectEqual(@as(u32, 20_000), long.duration_ms);

    const short = Fade.init(20, 19).?;
    try testing.expectEqual(@as(u32, 0), short.delay_ms);
    try testing.expectEqual(@as(u32, 19_000), short.duration_ms);

    try testing.expectEqual(@as(?Fade, null), Fade.init(0, 20));
    try testing.expectEqual(@as(?Fade, null), Fade.init(20, 0));
}

test "Fade: transparent until idle, linear, then stops ticking at black" {
    var f = Fade.init(10, 10).?;
    try testing.expectEqual(@as(f32, 0), f.alpha(5_000));
    try testing.expectEqual(@as(?i32, null), f.timeoutMs(5_000));

    f.start_ms = 1_000;
    try testing.expectEqual(@as(f32, 0.5), f.alpha(6_000));
    try testing.expectEqual(@as(?i32, Fade.tick_ms), f.timeoutMs(6_000));
    try testing.expectEqual(@as(f32, 1), f.alpha(30_000));
    try testing.expectEqual(@as(?i32, null), f.timeoutMs(30_000));

    f.start_ms = null;
    try testing.expectEqual(@as(f32, 0), f.alpha(30_000));
}
