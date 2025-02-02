const std = @import("std");
const evdev = @import("evdev");

pub fn main() !void {
    const dev = try evdev.Device.open("/dev/input/event3", .{});
    defer dev.closeAndFree();
    std.debug.print("name: {s}\n", .{dev.getName()});
    std.debug.print("is keyboard:            {}\n", .{dev.isKeyboard()});
    std.debug.print("is mouse:               {}\n", .{dev.isMouse()});
    std.debug.print("is gamepad:             {}\n", .{dev.isGamepad()});
    std.debug.print("is multi-touch device:  {}\n", .{dev.isMultiTouch()});
    std.debug.print("is single-touch device: {}\n", .{dev.isSingleTouch()});
}
