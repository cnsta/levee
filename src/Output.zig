const Output = @This();

const std = @import("std");
const log = std.log.scoped(.output);
const math = std.math;
const posix = std.posix;
const system = std.posix.system;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const Lock = @import("Lock.zig");

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,

configured: bool = false,
width: u31 = undefined,
height: u31 = undefined,

shm: ?*ShmDoubleBuffer = null,

link: wl.list.Link,

pub fn createSurface(output: *Output) !void {
    const surface = try output.lock.compositor.?.createSurface();
    output.surface = surface;

    const lock_surface = try output.lock.session_lock.?.getLockSurface(surface, output.wl_output);
    lock_surface.setListener(*Output, lockSurfaceListener, output);
    output.lock_surface = lock_surface;
}

pub fn destroy(output: *Output) void {
    output.wl_output.release();
    if (output.lock_surface) |s| s.destroy();
    if (output.surface) |s| s.destroy();
    if (output.shm) |sb| sb.deinitIfIdle();

    output.link.remove();
    output.lock.gpa.destroy(output);
}

pub fn draw(output: *Output, color: u24) void {
    if (!output.configured) return;
    const sb = output.shm orelse return;

    const buffer = sb.pickFree() orelse {
        log.warn("no free shm buffer to draw into, dropping frame", .{});
        return;
    };

    @memset(buffer.pixels, @as(u32, color));
    buffer.busy = true;

    const surface = output.surface.?;
    surface.attach(buffer.wl_buffer, 0, 0);
    surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));
    surface.commit();
}

fn ensureShm(output: *Output) !void {
    if (output.shm) |sb| {
        if (sb.width == output.width and sb.height == output.height) return;
        sb.deinitIfIdle();
    }
    output.shm = try ShmDoubleBuffer.create(output.lock.gpa, output.lock.shm.?, output.width, output.height);
}

fn lockSurfaceListener(
    _: *ext.SessionLockSurfaceV1,
    event: ext.SessionLockSurfaceV1.Event,
    output: *Output,
) void {
    switch (event) {
        .configure => |ev| {
            output.configured = true;
            output.width = @min(math.maxInt(u31), ev.width);
            output.height = @min(math.maxInt(u31), ev.height);
            output.lock_surface.?.ackConfigure(ev.serial);

            output.ensureShm() catch |err| {
                log.err("failed to allocate shm buffers: {s}", .{@errorName(err)});
                return;
            };
            output.draw(output.lock.rgb(output.lock.color));
        },
    }
}

const ShmDoubleBuffer = struct {
    gpa: std.mem.Allocator,
    fd: posix.fd_t,
    mem: []align(std.heap.page_size_min) u8,
    pool: *wl.ShmPool,
    buffers: [2]Buffer,
    width: u31,
    height: u31,

    const Buffer = struct {
        wl_buffer: *wl.Buffer,
        pixels: []u32,
        busy: bool = false,
    };

    fn create(gpa: std.mem.Allocator, shm: *wl.Shm, width: u31, height: u31) !*ShmDoubleBuffer {
        const stride: usize = @as(usize, width) * 4;
        const single_size: usize = stride * height;
        const total_size: usize = single_size * 2;

        const fd = try posix.memfd_create("levee-output", posix.MFD.CLOEXEC);
        errdefer _ = system.close(fd);

        switch (posix.errno(system.ftruncate(fd, @intCast(total_size)))) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }

        const mem = try posix.mmap(
            null,
            total_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(mem);

        const pool = try shm.createPool(fd, @intCast(total_size));
        errdefer pool.destroy();

        const sb = try gpa.create(ShmDoubleBuffer);
        errdefer gpa.destroy(sb);

        sb.* = .{
            .gpa = gpa,
            .fd = fd,
            .mem = mem,
            .pool = pool,
            .buffers = undefined,
            .width = width,
            .height = height,
        };

        for (&sb.buffers, 0..) |*b, i| {
            const offset = single_size * i;
            const wl_buffer = try pool.createBuffer(
                @intCast(offset),
                width,
                height,
                @intCast(stride),
                .xrgb8888,
            );
            b.* = .{
                .wl_buffer = wl_buffer,
                .pixels = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(mem[offset..][0..single_size]))),
            };
            wl_buffer.setListener(*Buffer, bufferListener, b);
        }

        return sb;
    }

    fn pickFree(sb: *ShmDoubleBuffer) ?*Buffer {
        for (&sb.buffers) |*b| {
            if (!b.busy) return b;
        }
        return null;
    }

    fn deinitIfIdle(sb: *ShmDoubleBuffer) void {
        for (sb.buffers) |b| {
            if (b.busy) return;
        }
        for (sb.buffers) |b| b.wl_buffer.destroy();
        sb.pool.destroy();
        posix.munmap(sb.mem);
        _ = system.close(sb.fd);
        sb.gpa.destroy(sb);
    }

    fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, buffer: *Buffer) void {
        switch (event) {
            .release => buffer.busy = false,
        }
    }
};
