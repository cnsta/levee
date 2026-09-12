const Lock = @This();

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const mem = std.mem;
const posix = std.posix;
const system = std.posix.system;
const process = std.process;
const fatal = process.fatal;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const xkb = @import("xkbcommon");

const auth = @import("auth.zig");
const Secret = @import("Secret.zig");
const list = @import("util/list.zig");

pub const Color = enum { init, input, input_alt, fail };

pub const Options = struct {
    ready_fd: ?posix.fd_t = null,
    ignore_empty_password: bool = false,
    init_color: u24 = 0x002b36,
    input_color: u24 = 0x6c71c4,
    input_alt_color: u24 = 0x6c71c4,
    fail_color: u24 = 0xdc322f,
};

gpa: mem.Allocator,
username: []const u8,
options: Options,

state: enum {
    initializing,
    locking,
    locked,
    exiting,
} = .initializing,

color: Color = .init,
secret: Secret,
in_flight: ?auth.Attempt = null,

pollfds: [2]posix.pollfd,

display: *wl.Display,
compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,

xkb_context: *xkb.Context,

fn flushWaylandAndPrepareRead(lock: *Lock) void {
    while (!lock.display.prepareRead()) {
        const errno = lock.display.dispatchPending();
        if (errno != .SUCCESS) {
            fatal("failed to dispatch pending wayland events: {s}", .{@tagName(errno)});
        }
    }

    while (true) {
        const errno = lock.display.flush();
        switch (errno) {
            .SUCCESS => return,
            .PIPE => {
                _ = lock.display.readEvents();
                fatal("connection to wayland server unexpectedly terminated", .{});
            },
            .AGAIN => {
                var wayland_out = [_]posix.pollfd{.{
                    .fd = lock.display.getFd(),
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&wayland_out, -1) catch |err| {
                    fatal("poll() failed: {s}", .{@errorName(err)});
                };
            },
            else => fatal("failed to flush wayland requests: {s}", .{@tagName(errno)}),
        }
    }
}

fn deinit(lock: *Lock) void {
    if (lock.compositor) |c| c.destroy();
    if (lock.shm) |s| s.destroy();

    assert(lock.session_lock_manager == null);
    assert(lock.session_lock == null);

    while (lock.seats.first()) |seat| seat.destroy();
    while (lock.outputs.first()) |output| output.destroy();

    lock.display.disconnect();
    lock.xkb_context.unref();

    lock.secret.clear();

    lock.* = undefined;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, lock: *Lock) void {
    lock.handleRegistryEvent(registry, event) catch |err| switch (err) {
        error.OutOfMemory => log.err("out of memory handling a registry event", .{}),
    };
}

fn handleRegistryEvent(lock: *Lock, registry: *wl.Registry, event: wl.Registry.Event) !void {
    switch (event) {
        .global => |ev| {
            if (mem.orderZ(u8, ev.interface, wl.Compositor.interface.name) == .eq) {
                if (ev.version < 4) fatal("advertised wl_compositor version too old, need >= 4", .{});
                lock.compositor = try registry.bind(ev.name, wl.Compositor, 4);
            } else if (mem.orderZ(u8, ev.interface, wl.Shm.interface.name) == .eq) {
                lock.shm = try registry.bind(ev.name, wl.Shm, 1);
            } else if (mem.orderZ(u8, ev.interface, ext.SessionLockManagerV1.interface.name) == .eq) {
                lock.session_lock_manager = try registry.bind(ev.name, ext.SessionLockManagerV1, 1);
            } else if (mem.orderZ(u8, ev.interface, wl.Output.interface.name) == .eq) {
                if (ev.version < 4) fatal("advertised wl_output version too old, need >= 4", .{});
                const wl_output = try registry.bind(ev.name, wl.Output, 4);
                errdefer wl_output.release();

                switch (lock.state) {
                    .initializing, .exiting => {},
                }
            } else if (mem.orderZ(u8, ev.interface, wl.Seat.interface.name) == .eq) {
                if (ev.version < 5) fatal("advertised wl_seat version too old, need >= 5", .{});
                const wl_seat = try registry.bind(ev.name, wl.Seat, 5);
                errdefer wl_seat.release();
            }
        },
    }
}

fn sessionLockListener(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, lock: *Lock) void {
    switch (event) {
        .locked => {
            assert(lock.state == .locking);
            lock.state = .locked;
            if (lock.options.ready_fd) |fd| {
                const newline: [1]u8 = .{'\n'};
                if (system.write(fd, &newline, 1) < 0) {
                    log.err("failed to send readiness notification on -ready-fd", .{});
                }
                _ = system.close(fd);
                lock.options.ready_fd = null;
            }
        },
        .finished => {
            switch (lock.state) {
                .initializing => unreachable,
                .locking => {
                    log.err("the compositor denied our session lock request " ++
                        "(is another ext-session-lock client already running?)", .{});
                    process.exit(1);
                },
                .locked => {
                    log.info("the compositor unlocked the session, exiting", .{});
                    process.exit(0);
                },
                .exiting => {},
            }
        },
    }
}

pub fn submitPassword(lock: *Lock) void {
    assert(lock.state == .locked);
    if (lock.in_flight != null) return;

    if (lock.options.ignore_empty_password and lock.secret.isEmpty()) {
        log.info("ignoring submission of empty password", .{});
        return;
    }

    lock.in_flight = auth.begin(lock.username, lock.secret.slice()) catch |err| {
        log.err("failed to start authentication attempt: {s}", .{@errorName(err)});
        lock.setColor(.fail);
        lock.secret.clear();
        return;
    };
    lock.secret.clear();
}
