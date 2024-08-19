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

pub fn isMTDevice(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_TOUCH) //
    and self.hasEventCode(c.EV_ABS, c.ABS_MT_POSITION_X) and self.hasEventCode(c.EV_ABS, c.ABS_MT_POSITION_Y) //
    and self.hasEventCode(c.EV_ABS, c.ABS_MT_SLOT); // support MT protocol type B
}

pub fn isSTDevice(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_TOUCH) //
    and self.hasEventCode(c.EV_ABS, c.ABS_X) and self.hasEventCode(c.EV_ABS, c.ABS_Y) //
    and !self.isMTDevice();
}

pub fn isMouse(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.BTN_MOUSE) //
    and self.hasEventCode(c.EV_REL, c.REL_X) and self.hasEventCode(c.EV_REL, c.REL_Y);
}

pub fn isKeyboard(self: Device) bool {
    return self.hasEventCode(c.EV_KEY, c.KEY_SPACE) and self.hasEventCode(c.EV_KEY, c.KEY_A) and self.hasEventCode(c.EV_KEY, c.KEY_Z);
}

pub fn readEvents(self: Device) !?ArrayList(c.input_event) {
    var events = ArrayList(c.input_event).init(self.allocator);
    defer events.deinit();
    {
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
    }

    var result = ArrayList(c.input_event).init(self.allocator);
    errdefer result.deinit();

    var dropped = false;
    var start_idx: usize = 0;

    for (events.items, 0..) |ev, idx| {
        if (ev.type != c.EV_SYN) {
            continue;
        }

        switch (ev.code) {
            c.SYN_REPORT => if (dropped) {
                dropped = false;
            } else {
                try result.appendSlice(events.items[start_idx .. idx + 1]);
            },
            c.SYN_DROPPED => {
                dropped = true;
            },
            c.SYN_CONFIG => unreachable, // currently not used
            c.SYN_MT_REPORT => unreachable, // used for MT protocol type A
            else => unreachable,
        }

        start_idx = idx;
    }

    return result;
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

pub fn hasEventType(self: Device, typ: c_uint) bool {
    return c.libevdev_has_event_type(self.dev, typ) == 1;
}

pub fn hasEventCode(self: Device, typ: c_uint, code: c_uint) bool {
    return c.libevdev_has_event_code(self.dev, typ, code) == 1;
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
