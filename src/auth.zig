const std = @import("std");
const pam = @import("pam");

const posix = std.posix;
const system = std.posix.system;

const log = std.log.scoped(.auth);

const service = "levee";

pub const Attempt = struct {
    fd: posix.fd_t,
    pid: posix.pid_t,
};

pub fn begin(username: []const u8, password: []const u8) !Attempt {
    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(system.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
    }
    const read_fd = fds[0];
    const write_fd = fds[1];
    errdefer _ = system.close(read_fd);

    const rc = system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            _ = system.close(write_fd);
            return posix.unexpectedErrno(e);
        },
    }
    const pid: posix.pid_t = @intCast(rc);

    if (pid == 0) {
        _ = system.close(read_fd);
        child(username, password, write_fd);
    }

    _ = system.close(write_fd);
    return .{ .fd = read_fd, .pid = pid };
}

pub fn finish(attempt: Attempt) bool {
    defer _ = system.close(attempt.fd);

    var byte: [1]u8 = .{0};
    const n = posix.read(attempt.fd, &byte) catch |err| blk: {
        log.err("failed to read authentication result from child: {s}", .{@errorName(err)});
        break :blk 0;
    };

    var status: c_int = undefined;
    _ = system.waitpid(attempt.pid, &status, 0);

    return n == 1 and byte[0] == 1;
}

var current_password: ?[]const u8 = null;

fn child(username: []const u8, password: []const u8, write_fd: posix.fd_t) noreturn {
    current_password = password;

    var user_buf: [256:0]u8 = undefined;
    const user_z = std.fmt.bufPrintZ(&user_buf, "{s}", .{username}) catch {
        report(write_fd, false);
        std.process.exit(1);
    };

    var pamh: ?*pam.pam_handle_t = null;
    const conv: pam.pam_conv = .{ .conv = converse, .appdata_ptr = null };

    const start_result = pam.pam_start(service, user_z, &conv, &pamh);
    if (start_result != pam.PAM_SUCCESS) {
        log.err("pam_start failed: {s}", .{pam.pam_strerror(pamh, start_result)});
        report(write_fd, false);
        std.process.exit(1);
    }

    const auth_result = pam.pam_authenticate(pamh, 0);
    const ok = auth_result == pam.PAM_SUCCESS;

    if (ok) {
        const cred_result = pam.pam_setcred(pamh, pam.PAM_REINITIALIZE_CRED);
        if (cred_result != pam.PAM_SUCCESS) {
            log.warn("pam_setcred failed: {s}", .{pam.pam_strerror(pamh, cred_result)});
        }
        _ = pam.pam_end(pamh, cred_result);
    } else {
        log.err("pam_authenticate failed: {s}", .{pam.pam_strerror(pamh, auth_result)});
        _ = pam.pam_end(pamh, auth_result);
    }

    report(write_fd, ok);
    std.process.exit(if (ok) 0 else 1);
}

fn report(write_fd: posix.fd_t, ok: bool) void {
    const byte: [1]u8 = .{@intFromBool(ok)};
    if (system.write(write_fd, &byte, 1) < 0) {
        log.err("failed to report authentication result to parent", .{});
    }
    _ = system.close(write_fd);
}

fn converse(
    num_msg: c_int,
    c_msg: [*c][*c]const pam.struct_pam_message,
    c_resp: [*c][*c]pam.struct_pam_response,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const ally = std.heap.c_allocator;
    const password = current_password orelse return pam.PAM_CONV_ERR;

    const n: usize = @intCast(num_msg);

    const responses = ally.alloc(pam.struct_pam_response, n) catch return pam.PAM_BUF_ERR;
    @memset(responses, .{ .resp = null, .resp_retcode = 0 });
    c_resp.* = responses.ptr;

    for (0..n) |i| {
        const m = c_msg[i];
        if (m.*.msg_style == pam.PAM_PROMPT_ECHO_OFF) {
            responses[i].resp = ally.dupeZ(u8, password) catch return pam.PAM_BUF_ERR;
        }
    }
    return pam.PAM_SUCCESS;
}

test "begin/finish round-trips a failed authentication without hanging or leaking a zombie" {
    const attempt = try begin("this-user-should-not-exist-xyz", "wrong");
    try std.testing.expect(!finish(attempt));
}
