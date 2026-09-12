const std = @import("std");
const pam = @import("pam");

const flags = @import("flags.zig");

test {
    _ = @import("Secret.zig");
    _ = @import("auth.zig");
}
