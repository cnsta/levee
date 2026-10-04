const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = @import("wayland").Scanner.create(b, .{});

    scanner.addCustomProtocol(b.path("protocol/ext-session-lock-v1.xml"));
    scanner.addSystemProtocol("staging/ext-idle-notify/ext-idle-notify-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("ext_idle_notifier_v1", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const zigimg = b.dependency("zigimg", .{}).module("zigimg");

    const pam = b.addTranslateC(.{
        .root_source_file = b.path("src/pam.h"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });
    addNixIncludePaths(b, pam);

    const vpx = b.addTranslateC(.{
        .root_source_file = b.path("src/vpx.h"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });
    addNixIncludePaths(b, vpx);

    const exe = b.addExecutable(.{
        .name = "levee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "wayland", .module = wayland },
                .{ .name = "xkbcommon", .module = xkbcommon },
                .{ .name = "zigimg", .module = zigimg },
                .{ .name = "pam", .module = pam.createModule() },
                .{ .name = "vpx", .module = vpx.createModule() },
            },
        }),
    });

    exe.use_llvm = true;
    exe.use_lld = true;

    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("pam", .{});
    exe.root_module.linkSystemLibrary("vpx", .{});
    b.installArtifact(exe);

    const install_prefix = std.fs.path.resolve(b.allocator, &.{b.install_prefix}) catch @panic("OOM");
    if (std.mem.eql(u8, install_prefix, "/usr")) {
        b.installFile("pam.d/levee", "../etc/pam.d/levee");
    } else {
        b.installFile("pam.d/levee", "etc/pam.d/levee");
    }

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = exe.root_module });
    tests.use_llvm = true;
    tests.use_lld = true;
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addNixIncludePaths(b: *std.Build, tc: *std.Build.Step.TranslateC) void {
    const cflags = b.graph.environ_map.get("NIX_CFLAGS_COMPILE") orelse return;
    var it = std.mem.tokenizeScalar(u8, cflags, ' ');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "-isystem")) {
            if (it.next()) |path| tc.addSystemIncludePath(.{ .cwd_relative = path });
        }
    }
}
