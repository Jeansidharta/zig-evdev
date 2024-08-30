const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // configuration options
    const static = b.option(bool, "static", "Link statically with libevdev") orelse false;

    // libevdev
    const dep_libevdev = b.lazyDependency("libevdev", .{});
    const libevdev: ?*Build.Step.Compile = if (dep_libevdev) |dep|
        buildLibevdev(b, target, optimize, dep, static)
    else
        null;
    const libevdev_include: ?Build.LazyPath = if (libevdev) |lib|
        if (lib.installed_headers_include_tree) |tree| tree.getDirectory() else null
    else
        null;

    // event module
    const event_mod = b: {
        const exe = b.addExecutable(.{
            .name = "gen_event",
            .root_source_file = b.path("tools/gen_event.zig"),
            .target = b.graph.host,
            .link_libc = true,
        });
        if (libevdev) |lib| exe.root_module.linkLibrary(lib);
        if (libevdev_include) |p| exe.root_module.addIncludePath(p);
        break :b Build.Module.CreateOptions{
            .root_source_file = b.addRunArtifact(exe).addOutputFileArg("Event.zig"),
        };
    };

    // main module
    const mod = b.addModule("evdev", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (libevdev) |lib| mod.linkLibrary(lib);
    if (libevdev_include) |p| mod.addIncludePath(p);
    mod.addAnonymousImport("Event", event_mod);

    // tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (libevdev) |lib| tests.root_module.linkLibrary(lib);
    if (libevdev_include) |p| tests.root_module.addIncludePath(p);
    tests.root_module.addAnonymousImport("Event", event_mod);
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // examples
    const examples_step = b.step("examples", "Install all examples");
    inline for ([_][2][]const u8{
        .{ "ctrl2cap", "Swap CapsLock key for Control key" },
        .{ "hello", "Hello" },
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

fn buildLibevdev(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source: *Build.Dependency,
    static: bool,
) *Build.Step.Compile {
    const so_version = std.SemanticVersion{ .major = 2, .minor = 3, .patch = 0 };
    const lib = if (static)
        b.addStaticLibrary(.{
            .name = "evdev",
            .target = target,
            .optimize = optimize,
        })
    else
        b.addSharedLibrary(.{
            .name = "evdev",
            .target = target,
            .optimize = optimize,
            .version = so_version,
            .pic = true,
        });

    lib.linkLibC();
    lib.linkSystemLibrary("rt");

    const event_names_h = b: {
        const run = b.addRunArtifact(b.addExecutable(.{
            .name = "capture_out",
            .root_source_file = b.path("tools/capture_out.zig"),
            .target = target,
            .optimize = optimize,
        }));
        const out = run.addOutputFileArg("libevdev/event-names.h");
        run.addFileArg(source.path("libevdev/make-event-names.py"));
        run.addFileInput(source.path("libevdev/libevdev.h"));
        const os = switch (target.result.os.tag) {
            .linux => "linux",
            .freebsd => "freebsd",
            else => @panic("Unsupported OS"),
        };
        run.addFileArg(source.path(b.fmt("include/linux/{s}/input.h", .{os})));
        run.addFileArg(source.path(b.fmt("include/linux/{s}/input-event-codes.h", .{os})));
        break :b out;
    };

    lib.addIncludePath(event_names_h.dirname());
    lib.addIncludePath(b.path("tools/libevdev"));
    lib.addIncludePath(source.path("."));
    lib.addIncludePath(source.path("include"));

    const flags = &[_][]const u8{
        // c_std=gnu99
        "-std=gnu99",
        // warning_level=2
        "-Wall",
        "-Wextra",
        // cflags
        "-Wno-unused-parameter",
        "-fvisibility=hidden",
        "-Wmissing-prototypes",
        "-Wstrict-prototypes",
        // disable UB sanitizer, which is enabled by default by Zig
        "-fno-sanitize=undefined",
    };
    lib.addCSourceFiles(.{
        .root = source.path("."),
        .flags = flags,
        .files = &.{
            "libevdev/libevdev-uinput.c",
            "libevdev/libevdev.c",
            "libevdev/libevdev-names.c",
        },
    });

    lib.installHeader(source.path("libevdev/libevdev.h"), "libevdev/libevdev.h");
    lib.installHeader(source.path("libevdev/libevdev-uinput.h"), "libevdev/libevdev-uinput.h");

    b.installArtifact(lib);

    return lib;
}
