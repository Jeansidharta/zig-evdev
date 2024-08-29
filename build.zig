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
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    const examples_step = b.step("examples", "Install all examples");
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

        const artifact = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&artifact.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&artifact.step);
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step(b.fmt("example-{s}", .{example[0]}), example[1]);
        run_step.dependOn(&run_cmd.step);
    }
}

fn setupModule(m: *Build.Module, b: *Build) void {
    const gen_event = b.addExecutable(.{
        .name = "gen_event",
        .root_source_file = b.path("tools/gen_event.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    linkLibevdev(&gen_event.root_module, b);
    m.addAnonymousImport("Event", .{
        .root_source_file = b.addRunArtifact(gen_event).addOutputFileArg("Event.zig"),
    });
    linkLibevdev(m, b);
}

fn linkLibevdev(m: *Build.Module, b: *Build) void {
    m.linkSystemLibrary("libevdev", .{ .needed = true });
    if (b.lazyDependency("libevdev", .{})) |dep| m.addIncludePath(dep.path("."));
}
