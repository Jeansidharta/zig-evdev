const std = @import("std");

const module = @import("root.zig");
const Device = module.Device;
const Event = module.Event;
const Property = module.Property;

const rawModule = @import("raw.zig");

const VirtualDevice = @This();

raw: rawModule.UInputDevice,

pub fn fromDevice(dev: Device) !VirtualDevice {
    return .{ .raw = try rawModule.UInputDevice.createFromDevice(dev.raw) };
}

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

pub const Builder = struct {
    raw: rawModule.Device,

    pub fn new() Builder {
        return Builder{ .raw = rawModule.Device.new() };
    }

    pub fn build(self: Builder) !VirtualDevice {
        defer self.raw.free();
        return .{ .raw = try rawModule.UInputDevice.createFromDevice(self.raw) };
    }

    pub fn setName(self: *Builder, name: []const u8) void {
        return self.raw.setName(name);
    }

    pub fn enableProperty(self: *Builder, prop: Property) !void {
        return self.raw.enableProperty(prop);
    }

    pub fn disableProperty(self: *Builder, prop: Property) !void {
        return self.raw.disableProperty(prop);
    }

    pub fn enableEventType(self: *Builder, typ: Event.Type) !void {
        return self.raw.enableEventType(typ);
    }

    pub fn disableEventType(self: *Builder, typ: Event.Type) !void {
        return self.raw.disableEventType(typ);
    }

    pub fn enableEventCode(self: *Builder, code: Event.Code, data: ?rawModule.Device.EventCodeData) !void {
        return self.raw.enableEventCode(code, data);
    }

    pub fn disableEventCode(self: *Builder, code: Event.Code) !void {
        return self.raw.disableEventCode(code);
    }

    pub fn copyCapabilities(self: *Builder, src: Device) !void {
        inline for (0..@typeInfo(Property).@"enum".fields.len) |prop_u| {
            const prop: Property = @enumFromInt(prop_u);
            if (src.hasProperty(prop)) try self.enableProperty(prop);
        }
        inline for (@typeInfo(Event.Type).@"enum".fields) |field| {
            try self.copyEventCapabilities(src, @field(Event.Type, field.name));
        }
    }

    fn copyEventCapabilities(
        self: *Builder,
        src: Device,
        comptime typ: Event.Type,
    ) !void {
        if (!src.hasEventType(typ)) return;
        try self.enableEventType(typ);

        @setEvalBranchQuota(2000);
        const CodeType = typ.CodeType();
        inline for (@typeInfo(CodeType).@"enum".fields) |field| {
            const codeField = @field(CodeType, field.name); // Event.Code.{KEY,SYN,..}.XXX
            const code = codeField.intoCode(); // Event.Code

            if (src.hasEventCode(code)) try self.enableEventCode(code, switch (typ) {
                .abs => .{ .abs_info = src.getAbsInfo(codeField) },
                .rep => .{ .repeat = &src.getRepeat(codeField).? },
                else => null,
            });
        }
    }
};
