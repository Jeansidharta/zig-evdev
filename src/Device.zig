const c = @import("c_api.zig");

const std = @import("std");
const log = std.log.scoped(.evdev);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Device = @This();

dev: ?*c.libevdev,
allocator: Allocator,

pub fn new(allocator: Allocator, name: [*c]const u8) !Device {
    const dev: ?*c.libevdev = c.libevdev_new();
    c.libevdev_set_name(dev, name);
    return Device{
        .dev = dev,
        .allocator = allocator,
    };
}

pub fn fromFd(allocator: Allocator, fd: i32) !Device {
    var dev: ?*c.libevdev = undefined;
    const rc = c.libevdev_new_from_fd(@intCast(fd), &dev);
    if (rc < 0) {
        log.warn("failed to initialize a device: {s}", .{c.strerror(-rc)});
        return error.InitDeviceFailed;
    }
    return Device{
        .dev = dev,
        .allocator = allocator,
    };
}

pub fn free(self: Device) void {
    c.libevdev_free(self.dev);
}

// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-classification
// https://source.android.com/docs/core/interaction/input/touch-devices#touch-device-driver-requirements
// https://source.android.com/docs/core/interaction/input/input-device-configuration-files#rationale

pub fn isMultiTouch(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_TOUCH) //
    and self.hasEventCode(c.EV_ABS, c.ABS_MT_POSITION_X) and self.hasEventCode(c.EV_ABS, c.ABS_MT_POSITION_Y) //
    and 1 < self.getNumSlots() // support MT protocol type B
    and !self.isGamepad();
}

pub fn isSingleTouch(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_TOUCH) //
    and self.hasEventCode(c.EV_ABS, c.ABS_X) and self.hasEventCode(c.EV_ABS, c.ABS_Y) //
    and !self.isMultiTouch();
}

pub fn isGamepad(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_GAMEPAD);
}

pub fn isMouse(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_MOUSE) //
    and self.hasEventCode(c.EV_REL, c.REL_X) and self.hasEventCode(c.EV_REL, c.REL_Y);
}

pub fn isKeyboard(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.KEY_SPACE) and self.hasEventCode(c.EV_KEY, c.KEY_A) and self.hasEventCode(c.EV_KEY, c.KEY_Z);
}

pub fn readEvents(self: Device) !?[]const c.input_event {
    var events = ArrayList(c.input_event).init(self.allocator);
    defer events.deinit();

    var ev: c.input_event = undefined;
    // read events until SYN_REPORT event is received
    while (true) {
        ev = try self.nextEvent(ReadFlags.NORMAL) orelse return null;
        try events.append(ev);
        if (ev.type != c.EV_SYN) continue;
        if (ev.code == c.SYN_REPORT) break;
        if (ev.code != c.SYN_DROPPED) continue;
        // read all events currently available on the device when SYN_DROPPED event is received
        while (true) {
            log.info("handling dropped events...", .{});
            if (try self.nextEvent(ReadFlags.SYNC)) |ev2| {
                try events.append(ev2);
            } else break;
        }
    }

    return try removeInvalidEvents(self.allocator, events.items);
}

fn removeInvalidEvents(allocator: Allocator, events: []const c.input_event) Allocator.Error![]const c.input_event {
    var result = ArrayList(c.input_event).init(allocator);
    defer result.deinit();

    var dropped = false;
    var start_idx: usize = 0;

    for (events, 0..) |ev, idx| {
        if (ev.type != c.EV_SYN) continue;

        switch (ev.code) {
            c.SYN_DROPPED => dropped = true,
            c.SYN_REPORT => if (dropped) {
                dropped = false;
                start_idx = idx + 1;
            } else {
                try result.appendSlice(events[start_idx .. idx + 1]);
                start_idx = idx;
            },
            c.SYN_CONFIG => unreachable, // currently not used
            c.SYN_MT_REPORT => unreachable, // used for MT protocol type A
            else => unreachable,
        }
    }

    return try result.toOwnedSlice();
}

test "removeInvalidEvents" {
    const allocator = std.testing.allocator;
    // zig fmt: off
    const expected: []const c.input_event = &.{
        newEvent(c.EV_ABS, c.ABS_X,        9),
        newEvent(c.EV_ABS, c.ABS_Y,        8),
        newEvent(c.EV_SYN, c.SYN_REPORT,   0),
        // ---
        newEvent(c.EV_ABS, c.ABS_X,       11),
        newEvent(c.EV_KEY, c.BTN_TOUCH,    0),
        newEvent(c.EV_SYN, c.SYN_REPORT,   0),
    };
    const actual = try removeInvalidEvents(allocator, &.{
        newEvent(c.EV_ABS, c.ABS_X,        9),
        newEvent(c.EV_ABS, c.ABS_Y,        8),
        newEvent(c.EV_SYN, c.SYN_REPORT,   0),
        // ---
        newEvent(c.EV_ABS, c.ABS_X,       10),
        newEvent(c.EV_ABS, c.ABS_Y,       10),
        newEvent(c.EV_SYN, c.SYN_DROPPED,  0),
        newEvent(c.EV_ABS, c.ABS_Y,       15),
        newEvent(c.EV_SYN, c.SYN_REPORT,   0),
        // ---
        newEvent(c.EV_ABS, c.ABS_X,       11),
        newEvent(c.EV_KEY, c.BTN_TOUCH,    0),
        newEvent(c.EV_SYN, c.SYN_REPORT,   0),
    });
    // zig fmt: on
    defer allocator.free(actual);
    try std.testing.expectEqualDeep(expected, actual);
}

const ReadFlags = struct {
    const NORMAL = c.LIBEVDEV_READ_FLAG_NORMAL;
    const BLOCKING = c.LIBEVDEV_READ_FLAG_BLOCKING;
    const SYNC = c.LIBEVDEV_READ_FLAG_SYNC;
    const FORCE_SYNC = c.LIBEVDEV_READ_FLAG_FORCE_SYNC;
};

fn nextEvent(self: Device, flags: c_uint) !?c.input_event {
    var ev: c.input_event = undefined;
    const rc = c.libevdev_next_event(self.dev, flags, &ev);
    switch (rc) {
        c.LIBEVDEV_READ_STATUS_SUCCESS, c.LIBEVDEV_READ_STATUS_SYNC => {
            log.debug("event received: {s} {s}: {} (device: {s})", .{
                c.libevdev_event_type_get_name(ev.type),
                c.libevdev_event_code_get_name(ev.type, ev.code),
                ev.value,
                self.getName(),
            });
            return ev;
        },
        -c.EAGAIN => {
            log.debug("no events are currently available (device: {s})", .{self.getName()});
            return null;
        },
        else => {
            log.warn("failed to read a next event: {s} (device: {s})", .{
                c.strerror(-rc),
                self.getName(),
            });
            return error.ReadEventFailed;
        },
    }
}

pub fn getFd(self: Device) c_int {
    return c.libevdev_get_fd(self.dev);
}

pub fn getName(self: Device) [*c]const u8 {
    return c.libevdev_get_name(self.dev);
}

pub fn grab(self: Device) !void {
    const rc = c.libevdev_grab(self.dev, c.LIBEVDEV_GRAB);
    if (rc < 0) {
        log.warn("grab failed: {s} (device: {s})", .{ c.strerror(-rc), self.getName() });
        return error.GrabFailed;
    }
}

pub fn ungrab(self: Device) !void {
    const rc = c.libevdev_grab(self.dev, c.LIBEVDEV_UNGRAB);
    if (rc < 0) {
        log.warn("ungrab failed: {s} (device: {s})", .{ c.strerror(-rc), self.getName() });
        return error.UngrabFailed;
    }
}

pub fn copyCapabilities(self: Device, src: Device) !void {
    inline for (0..@typeInfo(Property).Enum.fields.len) |prop_u| {
        const prop: Property = @enumFromInt(prop_u);
        if (src.hasProperty(prop)) {
            try self.enableProperty(prop);
        }
    }
    inline for ([_][2]c_int{
        .{ c.EV_KEY, c.KEY_CNT },
        .{ c.EV_REL, c.REL_CNT },
        .{ c.EV_ABS, c.ABS_CNT },
        .{ c.EV_MSC, c.MSC_CNT },
        .{ c.EV_SW, c.SW_CNT },
        .{ c.EV_LED, c.LED_CNT },
        .{ c.EV_SND, c.SND_CNT },
        .{ c.EV_SND, c.SND_CNT },
        .{ c.EV_REP, c.REP_CNT },
        .{ c.EV_FF, c.FF_CNT },
    }) |ev| {
        try self.copyEventCapabilities(src, ev[0], ev[1]);
    }
}

fn copyEventCapabilities(
    self: Device,
    src: Device,
    comptime typ: c_uint,
    comptime code_count: c_uint,
) !void {
    if (!src.hasEventType(typ)) return;
    try self.enableEventType(typ);

    inline for (0..code_count) |code_u| {
        const code: c_uint = @intCast(code_u);
        if (src.hasEventCode(typ, code)) {
            const data = switch (typ) {
                c.EV_ABS => self.getABSInfo(code),
                else => null,
            };
            try self.enableEventCode(typ, code, data);
        }
    }
}

pub const Property = enum(c_uint) {
    pointer = c.INPUT_PROP_POINTER,
    direct = c.INPUT_PROP_DIRECT,
    buttonpad = c.INPUT_PROP_BUTTONPAD,
    semi_mt = c.INPUT_PROP_SEMI_MT,
    topbuttonpad = c.INPUT_PROP_TOPBUTTONPAD,
    pointing_stick = c.INPUT_PROP_POINTING_STICK,
    accelerometer = c.INPUT_PROP_ACCELEROMETER,
};

pub fn hasProperty(self: Device, prop: Property) bool {
    return c.libevdev_has_property(self.dev, @intFromEnum(prop)) == 1;
}

pub fn hasEventType(self: Device, typ: c_uint) bool {
    return c.libevdev_has_event_type(self.dev, typ) == 1;
}

pub fn hasEventCode(self: Device, typ: c_uint, code: c_uint) bool {
    return c.libevdev_has_event_code(self.dev, typ, code) == 1;
}

pub fn enableProperty(self: Device, prop: Property) !void {
    const rc = c.libevdev_enable_property(self.dev, @intFromEnum(prop));
    if (rc < 0) {
        log.warn("failed to enable property {}: {s} (device: {s})", .{
            prop,
            c.strerror(-rc),
            self.getName(),
        });
        return error.EnablePropertyFailed;
    }
}

pub fn enableEventType(self: Device, typ: c_uint) !void {
    const rc = c.libevdev_enable_event_type(self.dev, typ);
    if (rc < 0) {
        log.warn("failed to enable {s}: {s} (device: {s})", .{
            c.libevdev_event_type_get_name(typ),
            c.strerror(-rc),
            self.getName(),
        });
        return error.EnableEventTypeFailed;
    }
}

pub fn enableEventCode(self: Device, typ: c_uint, code: c_uint, data: ?*const anyopaque) !void {
    const rc = c.libevdev_enable_event_code(self.dev, typ, code, data);
    if (rc < 0) {
        log.warn("failed to enable {s}: {s} (device: {s})", .{
            c.libevdev_event_code_get_name(typ, code),
            c.strerror(-rc),
            self.getName(),
        });
        return error.EnableEventCodeFailed;
    }
}

fn getABSInfo(self: Device, axis: c_uint) [*c]const c.input_absinfo {
    return c.libevdev_get_abs_info(self.dev, axis);
}

fn getNumSlots(self: Device) c_int {
    return c.libevdev_get_num_slots(self.dev);
}

pub fn createVirtualDevice(self: *const Device) !VirtualDevice {
    var uidev: ?*c.libevdev_uinput = undefined;
    const rc = c.libevdev_uinput_create_from_device(self.dev, c.LIBEVDEV_UINPUT_OPEN_MANAGED, &uidev);
    if (rc < 0) {
        log.warn(
            "failed to create an uinput device: {s} (event device: {s})",
            .{ c.strerror(-rc), self.getName() },
        );
        return error.InitLibEvdevUInputFailed;
    }
    return VirtualDevice{ .uidev = uidev };
}

pub const VirtualDevice = struct {
    uidev: ?*c.libevdev_uinput,

    pub fn destroy(self: VirtualDevice) void {
        c.libevdev_uinput_destroy(self.uidev);
    }

    pub fn writeEvent(self: VirtualDevice, typ: c_ushort, code: c_ushort, value: c_int) !void {
        const rc = c.libevdev_uinput_write_event(self.uidev, typ, code, value);
        if (rc < 0) return error.WriteEventFailed;
    }

    pub fn getPath(self: VirtualDevice) [*c]const u8 {
        return c.libevdev_uinput_get_syspath(self.uidev);
    }
};

fn newEvent(typ: c_ushort, code: c_ushort, value: c_int) c.input_event {
    return c.input_event{
        .time = .{ .tv_sec = 0, .tv_usec = 0 },
        .type = typ,
        .code = code,
        .value = value,
    };
}
