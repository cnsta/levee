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
const gfx = @import("render.zig");
const Font = @import("render/font.zig");
const background = @import("background.zig");

lock: *Lock,
name: u32,
wl_output: *wl.Output,
surface: ?*wl.Surface = null,
lock_surface: ?*ext.SessionLockSurfaceV1 = null,

configured: bool = false,
width: u31 = undefined,
height: u31 = undefined,

shm: ?*ShmDoubleBuffer = null,

frame_cb: ?*wl.Callback = null,
stale: bool = false,

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
    if (output.frame_cb) |cb| cb.destroy();
    if (output.lock_surface) |s| s.destroy();
    if (output.surface) |s| s.destroy();
    if (output.shm) |sb| sb.deinitIfIdle();

    output.link.remove();
    output.lock.gpa.destroy(output);
}

pub fn render(output: *Output, lock: *const Lock) void {
    if (!output.configured) return;
    const sb = output.shm orelse return;

    const buffer = sb.pickFree() orelse {
        log.warn("no free shm buffer to draw into, dropping frame", .{});
        return;
    };

    const canvas: gfx.Canvas = .{ .pixels = buffer.pixels, .width = output.width, .height = output.height };
    const bg = lock.options.init_color;
    canvas.fill(bg);

    if (lock.background) |bgimg| {
        background.composite(canvas, bgimg.frames[lock.playback.index], lock.options.image_mode, bg);
    }

    const cx: f32 = @as(f32, @floatFromInt(output.width)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(output.height)) * 0.6;
    const min_dim: f32 = @floatFromInt(@min(output.width, output.height));
    const label_color: gfx.Color = 0x93a1a1;
    const status_gap: f32 = min_dim * 0.05;

    const dot_count = std.unicode.utf8CountCodepoints(lock.secret.slice()) catch lock.secret.len;
    if (dot_count > 0) {
        const scale: i32 = @intFromFloat(text_scale);
        const advance: f32 = @floatFromInt((Font.width + 1) * scale);
        const count_f: f32 = @floatFromInt(dot_count);
        const row_width: f32 = count_f * advance - @as(f32, @floatFromInt(scale));
        const start_x: f32 = cx - row_width / 2.0;
        const y0: f32 = cy - @as(f32, @floatFromInt(Font.height * scale)) / 2.0;
        var i: usize = 0;
        while (i < dot_count) : (i += 1) {
            const glyph_x: i32 = @intFromFloat(start_x + advance * @as(f32, @floatFromInt(i)));
            canvas.drawGlyph(glyph_x, @intFromFloat(y0), '*', lock.rgb(lock.color), scale);
        }
    }

    if (lock.caps_lock) {
        drawCentered(canvas, cx, cy - status_gap - 7.0 * text_scale, "CAPS LOCK", label_color);
    }

    switch (lock.color) {
        .fail => {
            var buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "WRONG PASSWORD ({d})", .{lock.attempt_count}) catch "WRONG PASSWORD";
            drawCentered(canvas, cx, cy + status_gap, label, label_color);
        },
        .verifying => drawCentered(canvas, cx, cy + status_gap, "VERIFYING", label_color),
        else => {},
    }

    buffer.busy = true;
    output.stale = false;

    const surface = output.surface.?;
    surface.attach(buffer.wl_buffer, 0, 0);
    surface.damageBuffer(0, 0, math.maxInt(i32), math.maxInt(i32));

    if (output.frame_cb == null) {
        if (lock.background) |bgimg| if (bgimg.isAnimated()) output.requestFrame(surface);
    }

    surface.commit();
}

fn requestFrame(output: *Output, surface: *wl.Surface) void {
    const cb = surface.frame() catch {
        log.warn("out of memory requesting a frame callback, animation will pace itself", .{});
        return;
    };
    cb.setListener(*Output, frameListener, output);
    output.frame_cb = cb;
}

fn frameListener(cb: *wl.Callback, event: wl.Callback.Event, output: *Output) void {
    switch (event) {
        .done => {
            cb.destroy();
            output.frame_cb = null;
            if (output.stale) output.render(output.lock);
        },
    }
}

pub fn canAnimate(output: *const Output) bool {
    return output.configured and output.frame_cb == null;
}

pub fn animate(output: *Output, lock: *const Lock) void {
    if (!output.configured) return;
    if (output.frame_cb != null) {
        output.stale = true;
        return;
    }
    output.render(lock);
}

const text_scale: f32 = 3.0;

fn drawCentered(canvas: gfx.Canvas, cx: f32, y: f32, label: []const u8, color: gfx.Color) void {
    const scale: i32 = @intFromFloat(text_scale);
    const w = gfx.textWidth(label, scale);
    const x0: i32 = @as(i32, @intFromFloat(cx)) - @divTrunc(w, 2);
    const y0: i32 = @intFromFloat(y);
    canvas.drawText(x0, y0, label, color, scale);
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
            output.render(output.lock);
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
