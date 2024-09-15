const std = @import("std");

pub const Event = @import("Event");
pub const Device = @import("Device.zig");
pub const VirtualDevice = @import("VirtualDevice.zig");
const raw = @import("raw.zig");
pub const Property = raw.Property;
pub const AbsInfo = raw.AbsInfo;

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("event_test.zig");
}
