const std = @import("std");
const pam = @import("pam");

const mem = std.mem;
const posix = std.posix;
const process = std.process;
const log = std.log;

const Lock = @import("Lock.zig");
const flags = @import("flags.zig");

test {
    _ = @import("Secret.zig");
    _ = @import("auth.zig");
}

const usage =
    \\usage: levee [options]
    \\
    \\  -h                         Print this help message and exit.
    \\  -log-level <level>         Set the log level to error, warning, info, or debug.
    \\
    \\  -ready-fd <fd>             Write a newline to fd once the session is locked
    \\                             (for a swayidle-driven wrapper to synchronize on).
    \\  -ignore-empty-password     Do not validate an empty password.
    \\
    \\  -init-color 0xRRGGBB       Set the initial color.
    \\  -input-color 0xRRGGBB      Set the color used after input.
    \\  -input-alt-color 0xRRGGBB  Set the alternate color used after input.
    \\  -fail-color 0xRRGGBB       Set the color used on authentication failure.
    \\
;

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "log-level", .kind = .arg },
        .{ .name = "ready-fd", .kind = .arg },
        .{ .name = "ignore-empty-password", .kind = .boolean },
        .{ .name = "init-color", .kind = .arg },
        .{ .name = "input-color", .kind = .arg },
        .{ .name = "input-alt-color", .kind = .arg },
        .{ .name = "fail-color", .kind = .arg },
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

    var options: Lock.Options = .{
        .ignore_empty_password = result.flags.@"ignore-empty-password",
    };
    if (result.flags.@"ready-fd") |raw| {
        options.ready_fd = std.fmt.parseInt(posix.fd_t, raw, 10) catch {
            log.err("invalid file descriptor '{s}'", .{raw});
            process.exit(1);
        };
    }
    const passwd: *pam.struct_passwd = pam.getpwuid(pam.getuid()) orelse {
        log.err("failed to look up the current user", .{});
        process.exit(1);
    };
    const username = try gpa.dupe(u8, mem.sliceTo(passwd.pw_name, 0));
    defer gpa.free(username);

    try Lock.run(gpa, username, options);
}
