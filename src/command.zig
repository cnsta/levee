const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const system = posix.system;
const linux = std.os.linux;

const log = std.log.scoped(.command);

const default_path = "/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin";

pub fn run(gpa: mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const prepared = prepare(arena.allocator(), argv) catch {
        log.err("out of memory running {s}", .{argv[0]});
        return;
    };

    const rc = system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| {
            log.err("fork failed running {s}: {t}", .{ argv[0], err });
            return;
        },
    }
    if (rc == 0) {
        _ = system.setsid();
        if (system.fork() != 0) std.c._exit(0);

        var empty = posix.sigemptyset();
        _ = system.sigprocmask(posix.SIG.SETMASK, &empty, null);
        _ = linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
        for (prepared.candidates) |path| _ = std.c.execve(path, prepared.argv, std.c.environ);
        std.c._exit(127);
    }

    var status: c_int = undefined;
    _ = system.waitpid(@intCast(rc), &status, 0);
    log.info("ran {s}", .{argv[0]});
}

const Prepared = struct {
    argv: [*:null]const ?[*:0]const u8,
    candidates: []const [*:0]const u8,
};

fn prepare(a: mem.Allocator, argv: []const []const u8) !Prepared {
    const c_argv = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, c_argv) |arg, *c| c.* = (try a.dupeZ(u8, arg)).ptr;

    var candidates: std.ArrayList([*:0]const u8) = .empty;
    if (mem.indexOfScalar(u8, argv[0], '/') != null) {
        try candidates.append(a, c_argv[0].?);
    } else {
        const path = if (std.c.getenv("PATH")) |p| mem.span(p) else default_path;
        var it = mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            try candidates.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, argv[0] }, 0));
        }
    }
    return .{ .argv = c_argv.ptr, .candidates = candidates.items };
}

/// a command-line flag's value: split on whitespace, no quoting or globbing,
/// so `wlopm --off *` passes a literal `*`.
pub fn split(a: mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |word| try out.append(a, word);
    return out.items;
}

const testing = std.testing;

test "split: words, literal globs, empty clears" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try split(a, "  wlopm --off\t* ");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("wlopm", got[0]);
    try testing.expectEqualStrings("*", got[2]);
    try testing.expectEqual(@as(usize, 0), (try split(a, "")).len);
}

test "prepare: PATH lookup only without a slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const abs = try prepare(arena.allocator(), &.{ "/bin/true", "x" });
    try testing.expectEqual(@as(usize, 1), abs.candidates.len);
    try testing.expectEqualStrings("x", mem.span(abs.argv[1].?));
    try testing.expect(abs.argv[2] == null);
}
