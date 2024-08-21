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

    inline for ([_][2][]const u8{
        .{ "ctrl2cap", "Swap CapsLock key for Control key" },
    }) |example| {
        const exe = b.addExecutable(.{
            .name = example[0],
            .root_source_file = b.path("examples/" ++ example[0] ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("evdev", mod);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        b.step(example[0], example[1]).dependOn(&run_cmd.step);
    }
}

fn setupModule(m: *Build.Module, b: *Build) void {
    if (b.lazyDependency("libevdev", .{})) |dep| {
        m.addIncludePath(dep.path("."));
    }
    m.linkSystemLibrary("libevdev", .{ .needed = true });

    const gen_event = b.addExecutable(.{
        .name = "gen_event",
        .root_source_file = b.path("tools/gen_event.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    m.addAnonymousImport("Event", .{
        .root_source_file = b.addRunArtifact(gen_event).addOutputFileArg("Event.zig"),
    });
}
