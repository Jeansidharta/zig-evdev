const c = @cImport({
    @cInclude("errno.h");
    @cInclude("string.h");

    @cInclude("libevdev/libevdev.h");
    @cInclude("libevdev/libevdev-uinput.h");
});

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.evdev);
const testing = std.testing;

const Event = @import("Event");

pub const AbsInfo = c.input_absinfo;

pub const Property = enum(c_uint) {
    pointer = c.INPUT_PROP_POINTER,
    direct = c.INPUT_PROP_DIRECT,
    buttonpad = c.INPUT_PROP_BUTTONPAD,
    semi_mt = c.INPUT_PROP_SEMI_MT,
    topbuttonpad = c.INPUT_PROP_TOPBUTTONPAD,
    pointing_stick = c.INPUT_PROP_POINTING_STICK,
    accelerometer = c.INPUT_PROP_ACCELEROMETER,
};

pub const Device = struct {
    dev: ?*c.libevdev,

    // Initialization and setup

    pub inline fn new() Device {
        return .{ .dev = c.libevdev_new() };
    }

    pub fn fromFd(fd: c_int) SetFdError!Device {
        var dev: ?*c.libevdev = undefined;
        if (c.libevdev_new_from_fd(fd, &dev) < 0) return SetFdError.SetFdFailed;
        return .{ .dev = dev };
    }

    pub fn free(self: Device) void {
        c.libevdev_free(self.dev);
    }

    pub fn grab(self: Device) error{GrabFailed}!void {
        const rc = c.libevdev_grab(self.dev, c.LIBEVDEV_GRAB);
        if (rc < 0) {
            log.warn("grab failed: {s} (device: {s})", .{ c.strerror(-rc), self.getName() });
            return error.GrabFailed;
        }
    }

    pub fn ungrab(self: Device) error{UngrabFailed}!void {
        const rc = c.libevdev_grab(self.dev, c.LIBEVDEV_UNGRAB);
        if (rc < 0) {
            log.warn("ungrab failed: {s} (device: {s})", .{ c.strerror(-rc), self.getName() });
            return error.UngrabFailed;
        }
    }

    pub const SetFdError = error{SetFdFailed};

    pub fn setFd(self: *Device, fd: c_int) SetFdError!void {
        if (c.libevdev_set_fd(self.dev, fd) < 0) return error.SetFdFailed;
    }

    pub fn changeFd(self: *Device, fd: c_int) error{ChangeFdFailed}!void {
        if (c.libevdev_change_fd(self.dev, fd) < 0) return error.ChangeFdFailed;
    }

    pub fn getFd(self: Device) ?c_int {
        const fd = c.libevdev_get_fd(self.dev);
        return if (fd == -1) null else fd;
    }

    // Querying device capabilities

    pub inline fn getName(self: Device) []const u8 {
        return std.mem.span(c.libevdev_get_name(self.dev));
    }

    pub inline fn hasProperty(self: Device, prop: Property) bool {
        return c.libevdev_has_property(self.dev, @intFromEnum(prop)) == 1;
    }

    pub inline fn hasEventType(self: Device, typ: Event.Type) bool {
        return c.libevdev_has_event_type(self.dev, typ.intoInt()) == 1;
    }

    pub inline fn hasEventCode(self: Device, code: Event.Code) bool {
        return c.libevdev_has_event_code(self.dev, code.getType().intoInt(), code.intoInt()) == 1;
    }

    pub inline fn getAbsInfo(self: Device, axis: Event.Code.ABS) [*c]const AbsInfo {
        return c.libevdev_get_abs_info(self.dev, axis.intoInt());
    }

    pub fn getRepeat(self: Device, repeat: Event.Code.REP) ?c_int {
        var val: c_int = 0;
        return if (switch (repeat) {
            .REP_DELAY => c.libevdev_get_repeat(self.dev, &val, null),
            .REP_PERIOD => c.libevdev_get_repeat(self.dev, null, &val),
        } == 0)
            val
        else
            null;
    }

    // Multi-touch related functions

    pub inline fn getNumSlots(self: Device) c_int {
        return c.libevdev_get_num_slots(self.dev);
    }

    // Modifying the appearance or capabilities of the device

    pub inline fn setName(self: *Device, name: []const u8) void {
        c.libevdev_set_name(self.dev, &name[0]);
    }

    pub fn enableProperty(self: *Device, prop: Property) error{EnablePropertyFailed}!void {
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

    pub fn disableProperty(self: *Device, prop: Property) error{DisablePropertyFailed}!void {
        const rc = c.libevdev_disable_property(self.dev, @intFromEnum(prop));
        if (rc < 0) {
            log.warn("failed to disable property {}: {s} (device: {s})", .{
                prop,
                c.strerror(-rc),
                self.getName(),
            });
            return error.DisablePropertyFailed;
        }
    }

    pub fn enableEventType(self: *Device, typ: Event.Type) error{EnableEventTypeFailed}!void {
        const rc = c.libevdev_enable_event_type(self.dev, typ.intoInt());
        if (rc < 0) {
            log.warn("failed to enable {s}: {s} (device: {s})", .{
                typ.getName(),
                c.strerror(-rc),
                self.getName(),
            });
            return error.EnableEventTypeFailed;
        }
    }

    pub fn disableEventType(self: *Device, typ: Event.Type) error{DisableEventTypeFailed}!void {
        const rc = c.libevdev_disable_event_type(self.dev, typ.intoInt());
        if (rc < 0) {
            log.warn("failed to disable {s}: {s} (device: {s})", .{
                typ.getName(),
                c.strerror(-rc),
                self.getName(),
            });
            return error.DisableEventTypeFailed;
        }
    }

    pub const EventCodeData = union(enum) {
        abs_info: [*c]const AbsInfo,
        repeat: *const c_int,
    };

    pub fn enableEventCode(self: *Device, code: Event.Code, data: ?EventCodeData) error{EnableEventCodeFailed}!void {
        const rc = c.libevdev_enable_event_code(
            self.dev,
            code.getType().intoInt(),
            code.intoInt(),
            if (data) |d| switch (d) {
                inline else => |i| @as(*const anyopaque, i),
            } else null,
        );
        if (rc < 0) {
            log.warn("failed to enable {s} {s}: {s} (device: {s})", .{
                code.getType().getName(),
                code.getName() orelse "?",
                c.strerror(-rc),
                self.getName(),
            });
            return error.EnableEventCodeFailed;
        }
    }

    pub fn disableEventCode(self: *Device, code: Event.Code) error{DisableEventCodeFailed}!void {
        const rc = c.libevdev_disable_event_code(self.dev, code.getType().intoInt(), code.intoInt());
        if (rc < 0) {
            log.warn("failed to disable {s} {s}: {s} (device: {s})", .{
                code.getType().getName(),
                code.getName() orelse "?",
                c.strerror(-rc),
                self.getName(),
            });
            return error.DisableEventCodeFailed;
        }
    }

    // Event handling

    pub const ReadFlags = struct {
        pub const NORMAL = c.LIBEVDEV_READ_FLAG_NORMAL;
        pub const BLOCKING = c.LIBEVDEV_READ_FLAG_BLOCKING;
        pub const SYNC = c.LIBEVDEV_READ_FLAG_SYNC;
        pub const FORCE_SYNC = c.LIBEVDEV_READ_FLAG_FORCE_SYNC;
    };

    pub fn nextEvent(self: Device, flags: c_uint) error{ReadEventFailed}!?Event {
        var ev: c.input_event = undefined;
        const rc = c.libevdev_next_event(self.dev, flags, &ev);
        switch (rc) {
            c.LIBEVDEV_READ_STATUS_SUCCESS, c.LIBEVDEV_READ_STATUS_SYNC => {
                const timeval = std.posix.timeval;

                const time: timeval = if (@hasField(timeval, "sec") and @hasField(timeval, "usec"))
                    .{ .sec = ev.time.tv_sec, .usec = ev.time.tv_usec }
                else if (@hasField(timeval, "tv_sec") and @hasField(timeval, "tv_usec"))
                    .{ .tv_sec = ev.time.tv_sec, .tv_usec = ev.time.tv_usec }
                else
                    @compileError("System architecture has unknown shape for std.posix.timeval");

                const e = Event{
                    .code = Event.Code.new(Event.Type.new(ev.type), ev.code),
                    .time = time,
                    .value = ev.value,
                };
                log.debug("event received: {s} {s}: {} (device: {s})", .{
                    e.code.getType().getName(),
                    e.code.getName() orelse "?",
                    e.value,
                    self.getName(),
                });
                return e;
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

    pub inline fn hasEventPending(self: Device) bool {
        return c.libevdev_has_event_pending(self.dev) == 1;
    }
};

pub const UInputDevice = struct {
    uidev: ?*c.libevdev_uinput,

    // uinput device creation

    pub fn createFromDevice(dev: Device) error{CreateUInputFailed}!UInputDevice {
        var uidev: ?*c.libevdev_uinput = undefined;
        const rc = c.libevdev_uinput_create_from_device(dev.dev, c.LIBEVDEV_UINPUT_OPEN_MANAGED, &uidev);
        if (rc < 0) {
            log.warn(
                "failed to create an uinput device: {s} (event device: {s})",
                .{ c.strerror(-rc), dev.getName() },
            );
            return error.CreateUInputFailed;
        }
        return .{ .uidev = uidev };
    }

    pub inline fn destroy(self: UInputDevice) void {
        c.libevdev_uinput_destroy(self.uidev);
    }

    pub inline fn getFd(self: UInputDevice) c_int {
        return c.libevdev_uinput_get_fd(self.uidev);
    }

    pub inline fn getSysPath(self: UInputDevice) []const u8 {
        return std.mem.span(c.libevdev_uinput_get_syspath(self.uidev));
    }

    pub inline fn getDevNode(self: UInputDevice) []const u8 {
        return std.mem.span(c.libevdev_uinput_get_devnode(self.uidev));
    }

    pub fn writeEvent(self: UInputDevice, code: Event.Code, value: c_int) error{WriteEventFailed}!void {
        const rc = c.libevdev_uinput_write_event(
            self.uidev,
            code.getType().intoInt(),
            code.intoInt(),
            value,
        );
        if (rc < 0) {
            log.warn("failed to write {s} {s}: {s} (devnode: {s})", .{
                code.getType().getName(),
                code.getName() orelse "?",
                c.strerror(-rc),
                self.getDevNode(),
            });
            return error.WriteEventFailed;
        }
    }
};
