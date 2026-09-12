const std = @import("std");
const pam = @import("pam");

const posix = std.posix;

const log = std.log.scoped(.auth);

const service = "delloc";

pub const Attempt = struct {
    fd: posix.fd_t,
    pid: posix.pid_t,
};

pub fn begin(username: []const u8, password: []const u8) !Attempt {
    // TODO(verify): pipe2 with CLOEXEC, and whether it lives in std.posix or
    _ = username;
    _ = password;
    return error.Unimplemented;
}

pub fn finish(attempt: Attempt) bool {
    _ = attempt;
    return false;
}

fn converse() callconv(.c) c_int {
    // TODO: fill pam_response with a strdup of the password for
    return pam.PAM_CONV_ERR;
}
