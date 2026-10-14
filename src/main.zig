const std = @import("std");
const pam = @import("pam");

const mem = std.mem;
const posix = std.posix;
const process = std.process;
const log = std.log;

const Lock = @import("Lock.zig");
const flags = @import("flags.zig");
const Config = @import("Config.zig");
const command = @import("command.zig");

test {
    _ = @import("Secret.zig");
    _ = @import("auth.zig");
    _ = @import("render.zig");
    _ = @import("background.zig");
    _ = @import("video.zig");
    _ = @import("video/mp4.zig");
    _ = @import("fade.zig");
    _ = @import("spinner.zig");
    _ = @import("reject.zig");
    _ = @import("Config.zig");
    _ = @import("command.zig");
}

const usage =
    \\usage: levee [options]
    \\
    \\  -h                         Print this help message and exit.
    \\  -log-level <level>         Set the log level to error, warning, info, or debug.
    \\  -config <path>             Read this config instead of
    \\                             $XDG_CONFIG_HOME/levee/config.zon. The flags below
    \\                             override it.
    \\
    \\  -ready-fd <fd>             Write a newline to fd once the session is locked
    \\                             (for a swayidle-driven wrapper to synchronize on).
    \\  -fork-on-lock              Fork to the background once the session is locked
    \\                             (lets `swayidle -w` carry on while locked).
    \\  -ignore-empty-password     Do not validate an empty password.
    \\
    \\  -init-color 0xRRGGBB       Set the initial color.
    \\  -input-color 0xRRGGBB      Set the color used after input.
    \\  -input-alt-color 0xRRGGBB  Set the alternate color used after input.
    \\  -verifying-color 0xRRGGBB  Set the color used while checking the password.
    \\  -fail-color 0xRRGGBB       Set the color used on authentication failure.
    \\
    \\  -image <path>              Set a background image (png, bmp, tga, qoi, jpeg, gif)
    \\                             or a VP8/VP9 video in .mp4. Animated gifs and videos
    \\                             play. Without one, the background is solid.
    \\  -mode <mode>               Set how the background image is scaled: fill (default),
    \\                             fit, stretch, center, or tile.
    \\
    \\  -fade-end <seconds>        Idle seconds after locking at which the screen is fully
    \\                             black (default 20), when -on-black runs.
    \\  -fade-duration <seconds>   Fade to black over this long, ending at -fade-end
    \\                             (default 20, capped at -fade-end; 0 skips the fade).
    \\  -on-black <command>        Run this once the screen is black, e.g.
    \\                             "wlopm --off *". Split on spaces, no shell.
    \\  -on-wake <command>         Run this on the next input or exit, e.g.
    \\                             "wlopm --on *". An empty string clears either.
    \\
;

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "config", .kind = .arg },
        .{ .name = "ready-fd", .kind = .arg },
        .{ .name = "fork-on-lock", .kind = .boolean },
        .{ .name = "ignore-empty-password", .kind = .boolean },
        .{ .name = "init-color", .kind = .arg },
        .{ .name = "input-color", .kind = .arg },
        .{ .name = "input-alt-color", .kind = .arg },
        .{ .name = "verifying-color", .kind = .arg },
        .{ .name = "fail-color", .kind = .arg },
        .{ .name = "image", .kind = .arg },
        .{ .name = "mode", .kind = .arg },
        .{ .name = "fade-end", .kind = .arg },
        .{ .name = "fade-duration", .kind = .arg },
        .{ .name = "on-black", .kind = .arg },
        .{ .name = "on-wake", .kind = .arg },
    }).parse(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        process.exit(1);
    };

    if (result.flags.h) {
        std.debug.print("{s}", .{usage});
        process.exit(0);
    }
    if (result.args.len != 0) {
        log.err("unknown option '{s}'", .{result.args[0]});
        std.debug.print("{s}", .{usage});
        process.exit(1);
    }

    if (result.flags.@"log-level") |level| {
        if (mem.eql(u8, level, "error")) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, "warning")) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, "info")) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, "debug")) {
            runtime_log_level = .debug;
        } else {
            log.err("invalid log level '{s}'", .{level});
            process.exit(1);
        }
    }

    // A bad config is logged and ignored: failing to lock is worse.
    var loaded: ?Config.Loaded = null;
    defer if (loaded) |*l| l.deinit();
    const default_path = try Config.defaultPath(gpa, init.environ_map);
    defer if (default_path) |p| gpa.free(p);
    if (result.flags.config orelse default_path) |path| {
        var report: ?[]const u8 = null;
        defer if (report) |r| gpa.free(r);
        loaded = try Config.load(gpa, init.io, path, init.environ_map.get("HOME"), &report);
        if (report) |r| log.err("ignoring config {s}: {s}", .{ path, r });
        if (loaded == null and report == null and result.flags.config != null) {
            log.err("config {s} not found, using the defaults", .{path});
        }
    }
    const config: Config = if (loaded) |l| l.config else .{};

    var options: Lock.Options = .{
        .ignore_empty_password = config.ignore_empty_password or result.flags.@"ignore-empty-password",
        .fork_on_lock = result.flags.@"fork-on-lock",
        .init_color = config.background.color,
        .input_color = config.colors.input,
        .input_alt_color = config.colors.input_alt,
        .verifying_color = config.colors.verifying,
        .fail_color = config.colors.fail,
        .image_path = config.background.path,
        .image_mode = config.background.mode,
        .fade_end_s = config.fade.end,
        .fade_duration_s = config.fade.duration,
        .on_black = config.fade.on_black,
        .on_wake = config.fade.on_wake,
    };
    if (result.flags.@"ready-fd") |raw| {
        options.ready_fd = std.fmt.parseInt(posix.fd_t, raw, 10) catch {
            log.err("invalid file descriptor '{s}'", .{raw});
            process.exit(1);
        };
    }
    if (result.flags.@"init-color") |raw| options.init_color = parseColor(raw);
    if (result.flags.@"input-color") |raw| {
        options.input_color = parseColor(raw);
        options.input_alt_color = parseColor(raw);
    }
    if (result.flags.@"input-alt-color") |raw| options.input_alt_color = parseColor(raw);
    if (result.flags.@"verifying-color") |raw| options.verifying_color = parseColor(raw);
    if (result.flags.@"fail-color") |raw| options.fail_color = parseColor(raw);
    if (result.flags.image) |raw| options.image_path = raw;
    if (result.flags.mode) |raw| {
        options.image_mode = if (mem.eql(u8, raw, "fill"))
            .fill
        else if (mem.eql(u8, raw, "fit"))
            .fit
        else if (mem.eql(u8, raw, "stretch"))
            .stretch
        else if (mem.eql(u8, raw, "center"))
            .center
        else if (mem.eql(u8, raw, "tile"))
            .tile
        else {
            log.err("invalid mode '{s}', expected one of: fill, fit, stretch, center, tile", .{raw});
            process.exit(1);
        };
    }

    if (result.flags.@"fade-end") |raw| options.fade_end_s = parseSeconds(raw);
    if (result.flags.@"fade-duration") |raw| options.fade_duration_s = parseSeconds(raw);

    var flag_arena = std.heap.ArenaAllocator.init(gpa);
    defer flag_arena.deinit();
    if (result.flags.@"on-black") |raw| options.on_black = try command.split(flag_arena.allocator(), raw);
    if (result.flags.@"on-wake") |raw| options.on_wake = try command.split(flag_arena.allocator(), raw);

    const passwd: *pam.struct_passwd = pam.getpwuid(pam.getuid()) orelse {
        log.err("failed to look up the current user", .{});
        process.exit(1);
    };
    const username = try gpa.dupe(u8, mem.sliceTo(passwd.pw_name, 0));
    defer gpa.free(username);

    try Lock.run(gpa, init.io, username, options);
}

fn parseColor(raw: []const u8) u24 {
    if (raw.len != 8 or !mem.eql(u8, raw[0..2], "0x")) fatalBadColor(raw);
    return std.fmt.parseUnsigned(u24, raw[2..], 16) catch fatalBadColor(raw);
}

fn parseSeconds(raw: []const u8) u32 {
    return std.fmt.parseUnsigned(u32, raw, 10) catch {
        log.err("invalid number of seconds '{s}'", .{raw});
        process.exit(1);
    };
}

fn fatalBadColor(raw: []const u8) noreturn {
    log.err("invalid color '{s}', expected format '0xRRGGBB'", .{raw});
    process.exit(1);
}

var runtime_log_level: log.Level = switch (@import("builtin").mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .err,
};

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;
    log.defaultLog(level, scope, format, args);
}
