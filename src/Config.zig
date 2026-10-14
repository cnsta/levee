const Config = @This();

const std = @import("std");
const mem = std.mem;
const zon = std.zon;
const Allocator = mem.Allocator;
const Io = std.Io;

const bgimg = @import("background.zig");

background: Background = .{},
colors: Colors = .{},
fade: Fade = .{},
ignore_empty_password: bool = false,

pub const Background = struct {
    /// an image (png, bmp, tga, qoi, jpeg, gif) or a VP8/VP9 .mp4, picked by
    /// content. `~/` is the home directory, relative paths are relative to
    /// the config file. Null shows `color` only.
    path: ?[]const u8 = null,
    mode: bgimg.Mode = .fill,
    color: u24 = 0x002b36,
};

pub const Colors = struct {
    input: u24 = 0x93a1a1,
    input_alt: u24 = 0x93a1a1,
    verifying: u24 = 0x93a1a1,
    fail: u24 = 0xdc322f,
};

pub const Fade = struct {
    /// idle seconds after lock.
    end: u32 = 20,
    /// fade to black over this long. (0 disables anim).
    duration: u32 = 20,
    /// run once the screen is black (argv, no shell), e.g. to turn the
    /// outputs off.
    on_black: []const []const u8 = &.{},
    /// run on the first input after `on_black` ran, or when levee exits.
    on_wake: []const []const u8 = &.{},
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,

    pub fn deinit(loaded: *Loaded) void {
        loaded.arena.deinit();
        loaded.* = undefined;
    }
};

pub fn parse(gpa: Allocator, source: [:0]const u8, report: *?[]const u8) error{OutOfMemory}!?Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var diag: zon.parse.Diagnostics = .{};

    const config = zon.parse.fromSliceAlloc(Config, arena.allocator(), source, &diag, .{
        .ignore_unknown_fields = false,
        .free_on_error = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            report.* = try std.fmt.allocPrint(gpa, "{f}", .{diag});
            arena.deinit();
            return null;
        },
    };

    return .{ .arena = arena, .config = config };
}

const max_bytes = 1 << 20;

pub fn load(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    home: ?[]const u8,
    report: *?[]const u8,
) error{OutOfMemory}!?Loaded {
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_bytes), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            report.* = try std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ path, err });
            return null;
        },
    };
    defer gpa.free(source);

    var loaded = try parse(gpa, source, report) orelse return null;
    errdefer loaded.deinit();
    if (loaded.config.background.path) |p| {
        loaded.config.background.path = try resolvePath(loaded.arena.allocator(), p, path, home);
    }
    return loaded;
}

pub fn resolvePath(arena: Allocator, path: []const u8, config_path: []const u8, home: ?[]const u8) ![]const u8 {
    if (mem.startsWith(u8, path, "~/")) {
        const h = home orelse return path;
        return std.fs.path.join(arena, &.{ h, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return path;
    const dir = std.fs.path.dirname(config_path) orelse return path;
    return std.fs.path.join(arena, &.{ dir, path });
}

pub fn defaultPath(gpa: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fmt.allocPrint(gpa, "{s}/levee/config.zon", .{xdg});
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) return try std.fmt.allocPrint(gpa, "{s}/.config/levee/config.zon", .{home});
    }
    return null;
}

const testing = std.testing;

test "the example config is valid" {
    const example: Config = @import("example_config");
    try testing.expect(example.background.path != null);
}

test "an empty config is all defaults" {
    var report: ?[]const u8 = null;
    var loaded = (try parse(testing.allocator, ".{}", &report)).?;
    defer loaded.deinit();
    try testing.expectEqualDeep(Config{}, loaded.config);
    try testing.expect(report == null);
}

test "a partial config leaves the rest at defaults" {
    var report: ?[]const u8 = null;
    var loaded = (try parse(testing.allocator,
        \\.{ .background = .{ .path = "/w.mp4", .mode = .tile }, .colors = .{ .fail = 0xff0000 } }
    , &report)).?;
    defer loaded.deinit();
    const c = loaded.config;
    try testing.expectEqualStrings("/w.mp4", c.background.path.?);
    try testing.expectEqual(bgimg.Mode.tile, c.background.mode);
    try testing.expectEqual(@as(u24, 0x002b36), c.background.color);
    try testing.expectEqual(@as(u24, 0xff0000), c.colors.fail);
    try testing.expectEqual(@as(u24, 0x93a1a1), c.colors.verifying);
    try testing.expectEqual(@as(u32, 20), c.fade.end);
}

test "unknown fields and wrong types are reported, not defaulted" {
    for ([_][:0]const u8{
        ".{ .colour = .{} }",
        ".{ .colors = .{ .fail = \"red\" } }",
        ".{ .background = .{ .mode = .zoom } }",
        ".{ .fade = .{ .end = -1 } }",
    }) |source| {
        var report: ?[]const u8 = null;
        try testing.expect(try parse(testing.allocator, source, &report) == null);
        try testing.expect(report.?.len > 0);
        testing.allocator.free(report.?);
    }
}

test "resolvePath: home, absolute, and config-relative" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = "/home/u/.config/levee/config.zon";
    try testing.expectEqualStrings("/home/u/w.png", try resolvePath(a, "~/w.png", cfg, "/home/u"));
    try testing.expectEqualStrings("~/w.png", try resolvePath(a, "~/w.png", cfg, null));
    try testing.expectEqualStrings("/srv/w.png", try resolvePath(a, "/srv/w.png", cfg, "/home/u"));
    try testing.expectEqualStrings("/home/u/.config/levee/w.png", try resolvePath(a, "w.png", cfg, "/home/u"));
}
