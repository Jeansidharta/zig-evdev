const c = @import("c_api.zig");

const std = @import("std");
const log = std.log.scoped(.evdev);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Event = @import("Event");

const Device = @This();

dev: ?*c.libevdev,
allocator: Allocator,

pub fn new(allocator: Allocator, name: [*c]const u8) Device {
    const dev: ?*c.libevdev = c.libevdev_new();
    c.libevdev_set_name(dev, name);
    return Device{
        .dev = dev,
        .allocator = allocator,
    };
}

pub fn open(allocator: Allocator, path: []const u8) !Device {
    const fd = try std.posix.open(path, .{}, 0o444);
    var dev: ?*c.libevdev = undefined;
    const rc = c.libevdev_new_from_fd(fd, &dev);
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
    if (self.getFd()) |fd| _ = std.c.close(fd);
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
            if (try self.nextEvent(ReadFlags.SYNC)) |ev2| {
                try events.append(ev2);
            } else break;
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

const ReadFlags = struct {
    const NORMAL = c.LIBEVDEV_READ_FLAG_NORMAL;
    const BLOCKING = c.LIBEVDEV_READ_FLAG_BLOCKING;
    const SYNC = c.LIBEVDEV_READ_FLAG_SYNC;
    const FORCE_SYNC = c.LIBEVDEV_READ_FLAG_FORCE_SYNC;
};

fn nextEvent(self: Device, flags: c_uint) !?Event {
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
            return Event{
                .code = Event.Code.new(Event.Type.new(ev.type), ev.code),
                .time = .{ .tv_sec = ev.time.tv_sec, .tv_usec = ev.time.tv_usec },
                .value = ev.value,
            };
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

pub fn copyCapabilities(self: Device, src: Device, force: bool) !void {
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
    self: Device,
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

pub const Property = enum(c_uint) {
    pointer = c.INPUT_PROP_POINTER,
    direct = c.INPUT_PROP_DIRECT,
    buttonpad = c.INPUT_PROP_BUTTONPAD,
    semi_mt = c.INPUT_PROP_SEMI_MT,
    topbuttonpad = c.INPUT_PROP_TOPBUTTONPAD,
    pointing_stick = c.INPUT_PROP_POINTING_STICK,
    accelerometer = c.INPUT_PROP_ACCELEROMETER,
};

pub fn getFd(self: Device) ?c_int {
    const fd = c.libevdev_get_fd(self.dev);
    return if (fd == -1) null else fd;
}

pub fn getName(self: Device) []const u8 {
    return std.mem.span(c.libevdev_get_name(self.dev));
}

pub fn hasProperty(self: Device, prop: Property) bool {
    return c.libevdev_has_property(self.dev, @intFromEnum(prop)) == 1;
}

pub fn hasEventType(self: Device, typ: Event.Type) bool {
    return c.libevdev_has_event_type(self.dev, typ.intoInt()) == 1;
}

pub fn hasEventCode(self: Device, code: Event.Code) bool {
    return c.libevdev_has_event_code(self.dev, code.getType().intoInt(), code.intoInt()) == 1;
}

fn getAbsInfo(self: Device, axis: Event.Code.ABS) [*c]const c.input_absinfo {
    return c.libevdev_get_abs_info(self.dev, axis.intoInt());
}

fn getNumSlots(self: Device) c_int {
    return c.libevdev_get_num_slots(self.dev);
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

pub fn disableProperty(self: Device, prop: Property) !void {
    const rc = c.libevdev_disable_property(self.dev, @intFromEnum(prop));
    if (rc < 0) {
        log.warn("failed to disable property {}: {s} (device: {s})", .{
            prop, c.strerror(-rc), self.getName(),
        });
        return error.DisablePropertyFailed;
    }
}

pub fn enableEventType(self: Device, typ: Event.Type) !void {
    const rc = c.libevdev_enable_event_type(self.dev, typ.intoInt());
    if (rc < 0) {
        log.warn("failed to enable {}: {s} (device: {s})", .{
            typ,
            c.strerror(-rc),
            self.getName(),
        });
        return error.EnableEventTypeFailed;
    }
}

pub fn disableEventType(self: Device, typ: Event.Type) !void {
    const rc = c.libevdev_disable_event_type(self.dev, typ.intoInt());
    if (rc < 0) {
        log.warn("failed to disable {}: {s} (device: {s})", .{
            typ,
            c.strerror(-rc),
            self.getName(),
        });
        return error.DisableEventTypeFailed;
    }
}

pub fn enableEventCode(self: Device, code: Event.Code, data: ?*const anyopaque) !void {
    const rc = c.libevdev_enable_event_code(self.dev, code.getType().intoInt(), code.intoInt(), data);
    if (rc < 0) {
        log.warn("failed to enable {}: {s} (device: {s})", .{
            code,
            c.strerror(-rc),
            self.getName(),
        });
        return error.EnableEventCodeFailed;
    }
}

pub fn disableEventCode(self: Device, code: Event.Code) !void {
    const rc = c.libevdev_disable_event_code(self.dev, code.getType().intoInt(), code.intoInt());
    if (rc < 0) {
        log.warn("failed to disable {}: {s} (device: {s})", .{
            code,
            c.strerror(-rc),
            self.getName(),
        });
        return error.DisableEventCodeFailed;
    }
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

    pub fn writeEvent(self: VirtualDevice, code: Event.Code, value: c_int) !void {
        const rc = c.libevdev_uinput_write_event(
            self.uidev,
            code.getType().intoInt(),
            code.intoInt(),
            value,
        );
        if (rc < 0) return error.WriteEventFailed;
    }

    pub fn getFd(self: VirtualDevice) c_int {
        return c.libevdev_uinput_get_fd(self.uidev);
    }

    pub fn getSysPath(self: VirtualDevice) []const u8 {
        return std.mem.span(c.libevdev_uinput_get_syspath(self.uidev));
    }

    pub fn getDevNode(self: VirtualDevice) []const u8 {
        return std.mem.span(c.libevdev_uinput_get_devnode(self.uidev));
    }
};
