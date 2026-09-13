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
const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const list = @import("util/list.zig");
const bgimg = @import("background.zig");

pub const Color = enum { init, input, input_alt, verifying, fail };

pub const Options = struct {
    ready_fd: ?posix.fd_t = null,
    ignore_empty_password: bool = false,
    init_color: u24 = 0x002b36,
    input_color: u24 = 0x6c71c4,
    input_alt_color: u24 = 0x6c71c4,
    verifying_color: u24 = 0x268bd2,
    fail_color: u24 = 0xdc322f,
    image_path: ?[]const u8 = null,
    image_mode: bgimg.Mode = .fill,
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
caps_lock: bool = false,
attempt_count: u32 = 0,
secret: Secret,
in_flight: ?auth.Attempt = null,
background: ?bgimg.DecodedImage = null,

pollfds: [2]posix.pollfd,

display: *wl.Display,
compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
session_lock_manager: ?*ext.SessionLockManagerV1 = null,
session_lock: ?*ext.SessionLockV1 = null,

seats: wl.list.Head(Seat, .link),
outputs: wl.list.Head(Output, .link),

xkb_context: *xkb.Context,

pub fn run(gpa: mem.Allocator, io: std.Io, username: []const u8, options: Options) !void {
    var background_image: ?bgimg.DecodedImage = null;
    if (options.image_path) |path| {
        background_image = bgimg.load(gpa, io, path) catch |err| blk: {
            log.warn(
                "failed to load background image '{s}': {s} (using the solid background color instead)",
                .{ path, @errorName(err) },
            );
            break :blk null;
        };
    } else {
        background_image = bgimg.loadDefault(gpa) catch |err| blk: {
            log.warn(
                "failed to load the built-in default background image: {s} (using the solid background color instead)",
                .{@errorName(err)},
            );
            break :blk null;
        };
    }

    var lock: Lock = .{
        .gpa = gpa,
        .username = username,
        .options = options,
        .secret = .init(),
        .pollfds = undefined,
        .display = wl.Display.connect(null) catch |err| {
            fatal("failed to connect to a wayland compositor: {s}", .{@errorName(err)});
        },
        .seats = undefined,
        .outputs = undefined,
        .xkb_context = xkb.Context.new(.no_flags) orelse fatalOom(),
        .background = background_image,
    };
    defer lock.deinit();

    lock.seats.init();
    lock.outputs.init();

    const poll_wayland = 0;
    const poll_auth = 1;

    lock.pollfds[poll_wayland] = .{ .fd = lock.display.getFd(), .events = posix.POLL.IN, .revents = 0 };
    lock.pollfds[poll_auth] = .{ .fd = -1, .events = 0, .revents = 0 };

    const registry = lock.display.getRegistry() catch fatalOom();
    defer registry.destroy();
    registry.setListener(*Lock, registryListener, &lock);

    {
        const errno = lock.display.roundtrip();
        if (errno != .SUCCESS) fatal("initial roundtrip failed: {s}", .{@tagName(errno)});
    }

    if (lock.compositor == null) fatalNotAdvertised(wl.Compositor);
    if (lock.shm == null) fatalNotAdvertised(wl.Shm);
    if (lock.session_lock_manager == null) fatalNotAdvertised(ext.SessionLockManagerV1);

    lock.session_lock = lock.session_lock_manager.?.lock() catch fatalOom();
    lock.session_lock.?.setListener(*Lock, sessionLockListener, &lock);

    lock.session_lock_manager.?.destroy();
    lock.session_lock_manager = null;

    assert(lock.state == .initializing);
    lock.state = .locking;

    {
        var it = list.safeIterator(Output, .link, &lock.outputs);
        while (it.next()) |output| {
            output.createSurface() catch {
                log.err("out of memory creating lock surface, dropping output", .{});
                output.destroy();
            };
        }
    }

    while (lock.state != .exiting) {
        lock.flushWaylandAndPrepareRead();

        lock.pollfds[poll_auth] = if (lock.in_flight) |a|
            .{ .fd = a.fd, .events = posix.POLL.IN, .revents = 0 }
        else
            .{ .fd = -1, .events = 0, .revents = 0 };

        _ = posix.poll(&lock.pollfds, -1) catch |err| {
            fatal("poll() failed: {s}", .{@errorName(err)});
        };

        if (lock.pollfds[poll_wayland].revents & posix.POLL.IN != 0) {
            const errno = lock.display.readEvents();
            if (errno != .SUCCESS) fatal("error reading wayland events: {s}", .{@tagName(errno)});
        } else {
            lock.display.cancelRead();
        }

        if (lock.in_flight != null and lock.pollfds[poll_auth].revents & posix.POLL.IN != 0) {
            const attempt = lock.in_flight.?;
            lock.in_flight = null;
            if (auth.finish(attempt)) {
                lock.session_lock.?.unlockAndDestroy();
                lock.session_lock = null;
                lock.state = .exiting;
            } else {
                lock.setColor(.fail);
            }
        }
    }

    const errno = lock.display.roundtrip();
    if (errno != .SUCCESS) fatal("final roundtrip failed: {s}", .{@tagName(errno)});
}

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
    if (lock.background) |*bg| bg.deinit(lock.gpa);
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

                const output = try lock.gpa.create(Output);
                errdefer lock.gpa.destroy(output);

                output.* = .{ .lock = lock, .name = ev.name, .wl_output = wl_output, .link = undefined };
                lock.outputs.prepend(output);

                switch (lock.state) {
                    .initializing, .exiting => {},
                    .locking, .locked => try output.createSurface(),
                }
            } else if (mem.orderZ(u8, ev.interface, wl.Seat.interface.name) == .eq) {
                if (ev.version < 5) fatal("advertised wl_seat version too old, need >= 5", .{});
                const wl_seat = try registry.bind(ev.name, wl.Seat, 5);
                errdefer wl_seat.release();
                try Seat.create(lock, ev.name, wl_seat);
            }
        },
        .global_remove => |ev| {
            var out_it = list.safeIterator(Output, .link, &lock.outputs);
            while (out_it.next()) |output| {
                if (output.name == ev.name) {
                    output.destroy();
                    break;
                }
            }
            var seat_it = list.safeIterator(Seat, .link, &lock.seats);
            while (seat_it.next()) |seat| {
                if (seat.name == ev.name) {
                    seat.destroy();
                    break;
                }
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
    lock.setColor(.verifying);
    lock.secret.clear();
}

pub fn rgb(lock: *const Lock, color: Color) u24 {
    return switch (color) {
        .init => lock.options.init_color,
        .input => lock.options.input_color,
        .input_alt => lock.options.input_alt_color,
        .verifying => lock.options.verifying_color,
        .fail => lock.options.fail_color,
    };
}

pub fn setColor(lock: *Lock, color: Color) void {
    if (lock.color == color) return;
    lock.color = color;
    if (color == .fail) lock.attempt_count += 1;
    lock.redrawAll();
}

pub fn setCapsLock(lock: *Lock, active: bool) void {
    if (lock.caps_lock == active) return;
    lock.caps_lock = active;
    lock.redrawAll();
}

pub fn redrawAll(lock: *Lock) void {
    var it = list.safeIterator(Output, .link, &lock.outputs);
    while (it.next()) |output| output.render(lock);
}

fn fatalOom() noreturn {
    fatal("out of memory during initialization", .{});
}

fn fatalNotAdvertised(comptime Global: type) noreturn {
    fatal("{s} not advertised by the compositor", .{Global.interface.name});
}
