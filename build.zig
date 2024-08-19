const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("evdev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    setupModule(mod, b);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    setupModule(&tests.root_module, b);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn setupModule(m: *Build.Module, b: *Build) void {
    if (b.lazyDependency("libevdev", .{})) |dep| {
        m.addIncludePath(dep.path("."));
    }
    m.linkSystemLibrary("libevdev", .{ .needed = true });
}
