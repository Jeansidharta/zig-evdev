const c = @cImport(@cInclude("linux/input.h"));

const std = @import("std");

pub fn main() !void {
    @setEvalBranchQuota(190000);
    const allocator = std.heap.page_allocator;

    const consts = comptime b: {
        var consts: []const []const u8 = &.{};
        for (@typeInfo(c).Struct.decls) |decl|
            consts = consts ++ &[_][]const u8{decl.name};
        break :b consts;
    };

    var s = std.ArrayList(u8).init(allocator);
    defer s.deinit();
    var w = s.writer();

    _ = w.write(
        \\code: Code,
        \\value: c_int,
        \\time: @import("std").posix.timeval,
        \\
        \\pub fn new(code: Code, value: c_int) @This() {
        \\    const Instant = @import("std").time.Instant;
        \\    const zero = Instant{ .timestamp = .{
        \\        .tv_sec = 0,
        \\        .tv_nsec = 0,
        \\    } };
        \\    const now = if (!@import("builtin").is_test) Instant.now() catch zero else zero;
        \\    return .{
        \\        .code = code,
        \\        .value = value,
        \\        .time = .{
        \\            .tv_sec = now.timestamp.tv_sec,
        \\            .tv_usec = @divTrunc(now.timestamp.tv_nsec, 1000),
        \\        },
        \\    };
        \\}
        \\
        \\
    ) catch {};

    // SYN, KEY, REL, ...
    const types = comptime b: {
        var types: []const []const u8 = &.{};
        for (consts) |cnst| {
            if (filter(cnst, "EV_"))
                types = types ++ &[_][]const u8{cnst["EV_".len..]};
        }
        break :b types;
    };

    {
        _ = w.write(
            \\pub const Type = enum(c_ushort) {
            \\
        ) catch {};
        defer _ = w.write(
            \\    pub inline fn new(integer: c_ushort) Type {
            \\        return @enumFromInt(integer);
            \\    }
            \\    pub inline fn intoInt(self: @This()) c_ushort {
            \\        return @intFromEnum(self);
            \\    }
            \\    pub inline fn CodeType(comptime self: @This()) type {
            \\        return @import("std").meta.TagPayload(Code, self);
            \\    }
            \\};
            \\
        ) catch {};
        inline for (types) |typ| w.print(
            \\    {s} = {},
            \\
        , .{ typ, @field(c, "EV_" ++ typ) }) catch {};
    }

    {
        _ = w.write(
            \\pub const Code = union(Type) {
            \\
        ) catch {};
        defer _ = w.write(
            \\    pub inline fn intoInt(self: @This()) c_ushort {
            \\        return switch (self) {
            \\            inline else => |c| c.intoInt(),
            \\        };
            \\    }
            \\    pub inline fn getType(self: @This()) Type {
            \\        return @import("std").meta.activeTag(self);
            \\    }
            \\};
            \\
        ) catch {};

        defer {
            _ = w.write(
                \\    pub inline fn new(@"type": Type, integer: c_ushort) Code {
                \\        return switch (@"type") {
                \\
            ) catch {};
            for (types) |typ| w.print(
                \\            .{0s} => {0s}.new(integer).intoCode(),
                \\
            , .{typ}) catch {};
            _ = w.write(
                \\        };
                \\    }
                \\
            ) catch {};
        }

        for (types) |typ| w.print(
            \\    {0s}: {0s},
            \\
        , .{typ}) catch {};

        inline for (types) |typ| {
            w.print(
                \\    pub const {s} = enum(c_ushort) {{
                \\
            , .{typ}) catch {};
            defer w.print(
                \\        pub inline fn new(integer: c_ushort) @This() {{
                \\            return @enumFromInt(integer);
                \\        }}
                \\        pub inline fn intoInt(self: @This()) c_ushort {{
                \\            return @intFromEnum(self);
                \\        }}
                \\        pub inline fn intoCode(self: @This()) Code {{
                \\            return Code{{ .{s} = self }};
                \\        }}
                \\    }};
                \\
            , .{typ}) catch {};

            const Alias = struct {
                name: []const u8,
                target: []const u8,
            };
            var vals = [_][]const u8{""} ** std.math.maxInt(c_ushort);
            var aliases = std.ArrayList(Alias).init(allocator);
            defer aliases.deinit();
            var is_empty = true;

            consts: inline for (consts) |cnst| {
                comptime if (!filter(cnst, typ ++ "_"))
                    if (!(std.mem.eql(u8, typ, "KEY") and filter(cnst, "BTN_")))
                        continue;
                comptime for (types) |t|
                    if (!std.mem.eql(u8, typ, t) and filter(cnst, t ++ "_"))
                        // - typ != t
                        // - cnst starts with both typ and t
                        if (typ.len < t.len)
                            // t includes typ
                            continue :consts;

                is_empty = false;

                const val = @field(c, cnst);
                defer vals[val] = cnst;
                if (vals[val].len != 0) {
                    try aliases.append(.{ .name = cnst, .target = vals[val] });
                } else {
                    w.print(
                        \\        {s} = {},
                        \\
                    , .{ cnst, val }) catch {};
                }
            }

            for (aliases.items) |alias| w.print(
                \\        pub const {s} = @This().{s};
                \\
            , .{ alias.name, alias.target }) catch {};

            if (is_empty) _ = w.write(
                \\        _,
                \\
            ) catch {};
        }
    }

    var args = std.process.args();
    _ = args.next();
    if (args.next()) |filename| {
        var out = try std.fs.cwd().createFileZ(filename, .{});
        defer out.close();
        try out.writeAll(s.items);
    } else {
        std.debug.print("{s}", .{s.items});
    }
}

fn filter(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix))
        return false;

    for ([_][]const u8{ "_VERSION", "_CNT", "_MAX" }) |s|
        if (std.mem.endsWith(u8, name, s))
            return false;

    return true;
}
