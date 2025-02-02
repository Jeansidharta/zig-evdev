const std = @import("std");
const log = std.log.scoped(.evdev);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const module = @import("root.zig");
const Event = module.Event;
const Property = module.Property;

const raw = @import("raw.zig");

const Device = @This();

raw: raw.Device,

pub fn open(path: []const u8) raw.Device.OpenError!Device {
    return Device{
        .raw = try raw.Device.open(path, .{}),
    };
}

pub fn free(self: Device) void {
    self.raw.free();
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

pub fn readEvents(self: Device, dest: *ArrayList(Event)) !usize {
    const dest_len = dest.items.len;

    var ev: Event = try self.nextEvent(ReadFlags.NORMAL) orelse return 0;
    // read events until SYN_REPORT event is received
    while (true) {
        ev = (try self.nextEvent(ReadFlags.NORMAL)).?;
        try dest.append(ev);
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
                try dest.append(ev2)
            else
                break;
        }
    }

    removeInvalidEvents(dest, dest_len);
    return dest.items.len - dest_len;
}

fn removeInvalidEvents(events: *ArrayList(Event), start_index: usize) void {
    var dropped = false;
    var start_idx = start_index;

    var idx = start_index;
    while (idx < events.items.len) : (idx += 1) {
        const syn = switch (events.items[idx].code) {
            .SYN => |e| e,
            else => continue,
        };
        switch (syn) {
            .SYN_DROPPED => {
                dropped = true;
            },
            .SYN_REPORT => if (dropped) {
                dropped = false;
                events.replaceRangeAssumeCapacity(start_idx, idx + 1 - start_idx, &.{});
                idx = start_idx - 1;
            } else {
                start_idx = idx + 1;
            },
            .SYN_CONFIG => unreachable, // currently not used
            .SYN_MT_REPORT => unreachable, // used for MT protocol type A
        }
    }
}

test removeInvalidEvents {
    const allocator = std.testing.allocator;
    // zig fmt: off
    const before: []const Event = &.{
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
    };
    const after: []const Event = &.{
        Event.new(.{ .ABS = .ABS_X },        9),
        Event.new(.{ .ABS = .ABS_Y },        8),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
        // ---
        Event.new(.{ .ABS = .ABS_X },       11),
        Event.new(.{ .KEY = .BTN_TOUCH },    0),
        Event.new(.{ .SYN = .SYN_REPORT },   0),
    };
    // zig fmt: on
    var events = ArrayList(Event).init(allocator);
    defer events.deinit();
    try events.appendSlice(before);
    removeInvalidEvents(&events, 0);
    try std.testing.expectEqualSlices(Event, after, events.items);
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

pub fn getPath(self: Device, buf: []u8) raw.Device.GetPathError![]const u8 {
    return self.raw.getPath(buf);
}

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

pub fn getAbsInfo(self: Device, axis: Event.Code.ABS) [*c]const raw.AbsInfo {
    return self.raw.getAbsInfo(axis);
}

pub fn getNumSlots(self: Device) c_int {
    return self.raw.getNumSlots();
}

pub fn getRepeat(self: Device, repeat: Event.Code.REP) ?c_int {
    return self.raw.getRepeat(repeat);
}
