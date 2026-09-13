const Seat = @This();

const std = @import("std");
const log = std.log.scoped(.seat);
const posix = std.posix;
const system = std.posix.system;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const xkb = @import("xkbcommon");

const Lock = @import("Lock.zig");

lock: *Lock,
name: u32,
wl_seat: *wl.Seat,
wl_pointer: ?*wl.Pointer = null,
wl_keyboard: ?*wl.Keyboard = null,
xkb_state: ?*xkb.State = null,

link: wl.list.Link,

pub fn create(lock: *Lock, name: u32, wl_seat: *wl.Seat) !void {
    const seat = try lock.gpa.create(Seat);
    errdefer lock.gpa.destroy(seat);

    seat.* = .{
        .lock = lock,
        .name = name,
        .wl_seat = wl_seat,
        .link = undefined,
    };
    lock.seats.prepend(seat);

    wl_seat.setListener(*Seat, seatListener, seat);
}

pub fn destroy(seat: *Seat) void {
    seat.wl_seat.release();
    if (seat.wl_pointer) |p| p.release();
    if (seat.wl_keyboard) |k| k.release();
    if (seat.xkb_state) |s| s.unref();

    seat.link.remove();
    seat.lock.gpa.destroy(seat);
}

fn seatListener(wl_seat: *wl.Seat, event: wl.Seat.Event, seat: *Seat) void {
    switch (event) {
        .name => {},
        .capabilities => |ev| {
            if (ev.capabilities.pointer and seat.wl_pointer == null) {
                seat.wl_pointer = wl_seat.getPointer() catch {
                    log.err("failed to allocate wl_pointer", .{});
                    return;
                };
                seat.wl_pointer.?.setListener(?*anyopaque, pointerListener, null);
            } else if (!ev.capabilities.pointer and seat.wl_pointer != null) {
                seat.wl_pointer.?.release();
                seat.wl_pointer = null;
            }

            if (ev.capabilities.keyboard and seat.wl_keyboard == null) {
                seat.wl_keyboard = wl_seat.getKeyboard() catch {
                    log.err("failed to allocate wl_keyboard", .{});
                    return;
                };
                seat.wl_keyboard.?.setListener(*Seat, keyboardListener, seat);
            } else if (!ev.capabilities.keyboard and seat.wl_keyboard != null) {
                seat.wl_keyboard.?.release();
                seat.wl_keyboard = null;
            }
        },
    }
}

fn pointerListener(wl_pointer: *wl.Pointer, event: wl.Pointer.Event, _: ?*anyopaque) void {
    switch (event) {
        .enter => |ev| wl_pointer.setCursor(ev.serial, null, 0, 0),
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, seat: *Seat) void {
    switch (event) {
        .enter, .leave => {},
        .keymap => |ev| {
            defer _ = system.close(ev.fd);

            if (ev.format != .xkb_v1) {
                log.err("unsupported keymap format {d}", .{@intFromEnum(ev.format)});
                return;
            }

            const keymap_string = posix.mmap(
                null,
                ev.size,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                ev.fd,
                0,
            ) catch |err| {
                log.err("failed to mmap keymap fd: {s}", .{@errorName(err)});
                return;
            };
            defer posix.munmap(keymap_string);

            const keymap = xkb.Keymap.newFromBuffer(
                seat.lock.xkb_context,
                keymap_string.ptr,
                keymap_string.len - 1,
                .text_v1,
                .no_flags,
            ) orelse {
                log.err("failed to parse xkb keymap", .{});
                return;
            };
            defer keymap.unref();

            const state = xkb.State.new(keymap) orelse {
                log.err("failed to create xkb state", .{});
                return;
            };
            defer state.unref();

            if (seat.xkb_state) |s| s.unref();
            seat.xkb_state = state.ref();
        },
        .modifiers => |ev| {
            if (seat.xkb_state) |xkb_state| {
                _ = xkb_state.updateMask(
                    ev.mods_depressed,
                    ev.mods_latched,
                    ev.mods_locked,
                    0,
                    0,
                    ev.group,
                );

                const caps_active = xkb_state.modNameIsActive(
                    xkb.names.mod.caps,
                    @enumFromInt(xkb.State.Component.mods_effective),
                ) == 1;
                seat.lock.setCapsLock(caps_active);
            }
        },
        .key => |ev| {
            if (ev.state != .pressed) return;
            if (seat.lock.state != .locked) return;

            const xkb_state = seat.xkb_state orelse return;

            const keycode = ev.key + 8;

            const keysym = xkb_state.keyGetOneSym(keycode);
            if (keysym == .NoSymbol) return;

            const lock = seat.lock;
            switch (@intFromEnum(keysym)) {
                @intFromEnum(xkb.Keysym.Return), @intFromEnum(xkb.Keysym.KP_Enter) => {
                    lock.submitPassword();
                    return;
                },
                @intFromEnum(xkb.Keysym.Escape) => {
                    lock.secret.clear();
                    lock.setColor(.init);
                    return;
                },
                @intFromEnum(xkb.Keysym.u) => {
                    const ctrl_active = xkb_state.modNameIsActive(
                        xkb.names.mod.ctrl,
                        @enumFromInt(xkb.State.Component.mods_depressed | xkb.State.Component.mods_latched),
                    ) == 1;
                    if (ctrl_active) {
                        lock.secret.clear();
                        lock.setColor(.init);
                        return;
                    }
                },
                @intFromEnum(xkb.Keysym.BackSpace) => {
                    lock.secret.backspace();
                    if (lock.secret.isEmpty()) {
                        lock.setColor(.init);
                    } else {
                        lock.redrawAll();
                    }
                    return;
                },
                else => {},
            }

            var scratch: [4]u8 = undefined;
            const len = xkb_state.keyGetUtf8(keycode, &scratch);
            if (len > 0) {
                lock.secret.append(scratch[0..len]);
                switch (lock.color) {
                    .init, .input_alt, .fail, .verifying => lock.setColor(.input),
                    .input => lock.setColor(.input_alt),
                }
            }
        },
        .repeat_info => {},
    }
}
