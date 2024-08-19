const std = @import("std");

pub const Device = @import("Device.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
