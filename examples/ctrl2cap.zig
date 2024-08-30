const std = @import("std");

const evdev = @import("evdev");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .evdev, .level = .err },
    },
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();
    defer _ = gpa_state.deinit();

    var args = std.process.args();
    _ = args.next();
    var keyboard = try evdev.Device.open(gpa, args.next().?);
    defer keyboard.free();
    std.debug.assert(keyboard.isKeyboard());

    var outdevice = evdev.Device.new(gpa, "ctrl2cap");
    defer outdevice.free();
    try outdevice.copyCapabilities(keyboard, false);
    var writer = try outdevice.createVirtualDevice();
    defer writer.destroy();

    try keyboard.grab();
    defer keyboard.ungrab() catch {};

    main: while (true) {
        const events = try keyboard.readEvents() orelse continue;
        defer gpa.free(events);
        for (events) |event| {
            std.debug.print("{}\n", .{event});
            var out = event;
            switch (out.code) {
                .KEY => |*k| switch (k.*) {
                    .KEY_CAPSLOCK => k.* = .KEY_LEFTCTRL,
                    .KEY_LEFTCTRL => k.* = .KEY_CAPSLOCK,
                    .KEY_Q => break :main,
                    else => {},
                },
                else => {},
            }
            try writer.writeEvent(out.code, out.value);
        }
    }
}
