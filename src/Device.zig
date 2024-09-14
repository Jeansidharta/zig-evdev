const std = @import("std");
const log = std.log.scoped(.evdev);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Event = @import("Event");
const raw = @import("raw.zig");

const Device = @This();

raw: raw.Device,
allocator: Allocator,

pub fn new(allocator: Allocator, name: [*c]const u8) Device {
    var dev = raw.Device.new();
    dev.setName(name);
    return Device{
        .raw = dev,
        .allocator = allocator,
    };
}

pub fn open(allocator: Allocator, path: []const u8) !Device {
    const fd = try std.posix.open(path, .{}, 0o444);
    var dev = raw.Device.new();
    try dev.setFd(fd);
    return Device{
        .raw = dev,
        .allocator = allocator,
    };
}

pub fn free(self: Device) void {
    defer self.raw.free();
    if (self.getFd()) |fd| std.posix.close(fd);
}

// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-classification
// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-driver-requirements
// https://source.android.com/docs/core/interaction/input/input-device-configuration-files#rationale

pub fn isMultiTouch(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .KEY = .BTN_TOUCH },
        .{ .ABS = .ABS_MT_POSITION_X },
        .{ .ABS = .ABS_MT_POSITION_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return 1 < self.getNumSlots() and !self.isGamepad();
}

pub fn isSingleTouch(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .KEY = .BTN_TOUCH },
        .{ .ABS = .ABS_X },
        .{ .ABS = .ABS_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return !self.isMultiTouch();
}

pub fn isGamepad(self: Device) bool {
    return self.hasEventCode(
        .{ .KEY = Event.Code.KEY.BTN_GAMEPAD },
    );
}

pub fn isMouse(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .KEY = Event.Code.KEY.BTN_MOUSE },
        .{ .REL = .REL_X },
        .{ .REL = .REL_Y },
    }) |code| if (!self.hasEventCode(code)) return false;
    return true;
}

pub fn isKeyboard(self: Device) bool {
    inline for ([_]Event.Code{
        .{ .KEY = .KEY_SPACE },
        .{ .KEY = .KEY_A },
        .{ .KEY = .KEY_Z },
    }) |code| if (!self.hasEventCode(code)) return false;
    return true;
}

pub fn readEvents(self: Device) !?[]const Event {
    var events = ArrayList(Event).init(self.allocator);
    defer events.deinit();

    var ev: Event = undefined;
    // read events until SYN_REPORT event is received
    while (true) {
        ev = try self.nextEvent(ReadFlags.NORMAL) orelse return null;
        try events.append(ev);
        const syn = switch (ev.code) {
            .SYN => |e| e,
            else => continue,
        };
        if (syn == .SYN_REPORT) break;
        if (syn != .SYN_DROPPED) continue;
        // read all events currently available on the device when SYN_DROPPED event is received
        while (true) {
            log.info("handling dropped events...", .{});
            if (try self.nextEvent(ReadFlags.SYNC)) |ev2|
                try events.append(ev2)
            else
                break;
        }
    }

    return try removeInvalidEvents(self.allocator, events.items);
}

fn removeInvalidEvents(allocator: Allocator, events: []const Event) Allocator.Error![]const Event {
    var result = ArrayList(Event).init(allocator);
    defer result.deinit();

    var dropped = false;
    var start_idx: usize = 0;

    for (events, 0..) |ev, idx| {
        const syn = switch (ev.code) {
            .SYN => |e| e,
            else => continue,
        };
        switch (syn) {
            .SYN_DROPPED => dropped = true,
            .SYN_REPORT => if (dropped) {
                dropped = false;
                start_idx = idx + 1;
            } else {
                try result.appendSlice(events[start_idx .. idx + 1]);
                start_idx = idx;
            },
            .SYN_CONFIG => unreachable, // currently not used
            .SYN_MT_REPORT => unreachable, // used for MT protocol type A
        }
    }

    return try result.toOwnedSlice();
}

test "removeInvalidEvents" {
    const allocator = std.testing.allocator;
    // zig fmt: off
    const expected: []const Event = &.{
        Event.new(.{ .ABS = .ABS_X },        9),
        Event.new(.{ .ABS = .ABS_Y },        8),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
        // ---
        Event.new(.{ .ABS = .ABS_X },       11),
        Event.new(.{ .KEY = .BTN_TOUCH },    0),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
    };
    const actual = try removeInvalidEvents(allocator, &.{
        Event.new(.{ .ABS = .ABS_X },        9),
        Event.new(.{ .ABS = .ABS_Y },        8),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
        // ---
        Event.new(.{ .ABS = .ABS_X },       10),
        Event.new(.{ .ABS = .ABS_Y },       10),
        Event.new(.{ .SYN = .SYN_DROPPED },  0),
        Event.new(.{ .ABS = .ABS_Y },       15),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
        // ---
        Event.new(.{ .ABS = .ABS_X },       11),
        Event.new(.{ .KEY = .BTN_TOUCH },    0),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
    });
    // zig fmt: on
    defer allocator.free(actual);
    try std.testing.expectEqualDeep(expected, actual);
}

const ReadFlags = raw.Device.ReadFlags;

fn nextEvent(self: Device, flags: c_uint) !?Event {
    return self.raw.nextEvent(flags);
}

pub fn grab(self: Device) !void {
    return self.raw.grab();
}

pub fn ungrab(self: Device) !void {
    return self.raw.ungrab();
}

pub fn copyCapabilities(self: *Device, src: Device, force: bool) !void {
    inline for (0..@typeInfo(Property).Enum.fields.len) |prop_u| {
        const prop: Property = @enumFromInt(prop_u);
        if (src.hasProperty(prop)) {
            self.enableProperty(prop) catch |e| if (force) return e;
        }
    }
    inline for (@typeInfo(Event.Type).Enum.fields) |field| {
        self.copyEventCapabilities(
            src,
            @field(Event.Type, field.name),
            force,
        ) catch |e| if (force) return e;
    }
}

fn copyEventCapabilities(
    self: *Device,
    src: Device,
    comptime typ: Event.Type,
    force: bool,
) !void {
    if (!src.hasEventType(typ)) return;
    self.enableEventType(typ) catch |e| if (force) return e;

    @setEvalBranchQuota(2000);
    const CodeType = typ.CodeType();
    inline for (@typeInfo(CodeType).Enum.fields) |field| {
        const codeField = @field(CodeType, field.name); // Event.Code.{KEY,SYN,..}.XXX
        const code = codeField.intoCode(); // Event.Code

        if (src.hasEventCode(code)) {
            const data = switch (typ) {
                .ABS => src.getAbsInfo(codeField),
                else => null,
            };
            self.enableEventCode(code, data) catch |e| if (force) return e;
        }
    }
}

pub const Property = raw.Property;

pub fn getFd(self: Device) ?c_int {
    return self.raw.getFd();
}

pub fn getName(self: Device) []const u8 {
    return self.raw.getName();
}

pub fn hasProperty(self: Device, prop: Property) bool {
    return self.raw.hasProperty(prop);
}

pub fn hasEventType(self: Device, typ: Event.Type) bool {
    return self.raw.hasEventType(typ);
}

pub fn hasEventCode(self: Device, code: Event.Code) bool {
    return self.raw.hasEventCode(code);
}

fn getAbsInfo(self: Device, axis: Event.Code.ABS) raw.AbsInfo {
    return self.raw.getAbsInfo(axis);
}

fn getNumSlots(self: Device) c_int {
    return self.raw.getNumSlots();
}

pub fn enableProperty(self: *Device, prop: Property) !void {
    return self.raw.enableProperty(prop);
}

pub fn disableProperty(self: *Device, prop: Property) !void {
    return self.raw.disableProperty(prop);
}

pub fn enableEventType(self: *Device, typ: Event.Type) !void {
    return self.raw.enableEventType(typ);
}

pub fn disableEventType(self: *Device, typ: Event.Type) !void {
    return self.raw.disableEventType(typ);
}

pub fn enableEventCode(self: *Device, code: Event.Code, data: ?*const anyopaque) !void {
    return self.raw.enableEventCode(code, data);
}

pub fn disableEventCode(self: *Device, code: Event.Code) !void {
    return self.raw.disableEventCode(code);
}

pub fn createVirtualDevice(self: Device) !VirtualDevice {
    return .{ .raw = try raw.UInputDevice.createFromDevice(self.raw) };
}

pub const VirtualDevice = struct {
    raw: raw.UInputDevice,

    pub fn destroy(self: VirtualDevice) void {
        return self.raw.destroy();
    }

    pub fn writeEvent(self: VirtualDevice, code: Event.Code, value: c_int) !void {
        return self.raw.writeEvent(code, value);
    }

    pub fn getFd(self: VirtualDevice) c_int {
        return self.raw.getFd();
    }

    pub fn getSysPath(self: VirtualDevice) []const u8 {
        return self.raw.getSysPath();
    }

    pub fn getDevNode(self: VirtualDevice) []const u8 {
        return self.raw.getDevNode();
    }
};
