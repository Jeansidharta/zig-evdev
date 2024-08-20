const c = @cImport(@cInclude("linux/input.h"));

const std = @import("std");

pub fn main() !void {
    @setEvalBranchQuota(20000);

    const consts = comptime b: {
        var consts: []const []const u8 = &.{};
        for (@typeInfo(c).Struct.decls) |decl|
            consts = consts ++ &[_][]const u8{decl.name};
        break :b consts;
    };

    comptime var code: []const u8 =
        \\code: Code,
        \\value: c_int,
        \\time: @import("std").posix.timeval,
        \\
        \\pub fn new(code: Code, value: c_int) @This() {
        \\    const Instant = @import("std").time.Instant;
        \\    const zero = Instant{ .timestamp = .{
        \\        .tv_sec = 0,
        \\        .tv_nsec = 0 
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
    ;

    // SYN, KEY, REL, ...
    const types = comptime b: {
        var types: []const []const u8 = &.{};
        for (consts) |cnst| {
            if (filter(cnst, "EV_"))
                types = types ++ &[_][]const u8{cnst["EV_".len..]};
        }
        break :b types;
    };

    comptime {
        code = code ++
            \\pub const Type = enum(c_ushort) {
            \\
        ;
        defer code = code ++
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
        ;
        for (types) |typ| code = code ++ std.fmt.comptimePrint(
            \\    {s} = {},
            \\
        , .{ typ, @field(c, "EV_" ++ typ) });
    }

    comptime {
        code = code ++
            \\pub const Code = union(Type) {
            \\
        ;
        defer code = code ++
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
        ;

        defer {
            code = code ++
                \\    pub inline fn new(@"type": Type, integer: c_ushort) Code {
                \\        return switch (@"type") {
                \\
            ;
            for (types) |typ| code = code ++ std.fmt.comptimePrint(
                \\            .{0s} => {0s}.new(integer).intoCode(),
                \\
            , .{typ});
            code = code ++
                \\        };
                \\    }
                \\
            ;
        }

        for (types) |typ| code = code ++ std.fmt.comptimePrint(
            \\    {0s}: {0s},
            \\
        , .{typ});

        for (types) |typ| {
            code = code ++ std.fmt.comptimePrint(
                \\    pub const {s} = enum(c_ushort) {{
                \\
            , .{typ});
            defer code = code ++ std.fmt.comptimePrint(
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
            , .{typ});

            const Alias = struct {
                name: []const u8,
                target: []const u8,
            };
            var vals = [_][]const u8{""} ** std.math.maxInt(c_ushort);
            var aliases: []const Alias = &.{};
            var is_empty = true;

            consts: for (consts) |cnst| {
                if (!filter(cnst, typ ++ "_"))
                    if (!(std.mem.eql(u8, typ, "KEY") and filter(cnst, "BTN_")))
                        continue;
                for (types) |t| {
                    if (std.mem.eql(u8, typ, t) or !filter(cnst, t ++ "_"))
                        continue;
                    // - typ != t
                    // - cnst starts with both typ and t
                    if (typ.len < t.len)
                        // t includes typ
                        continue :consts;
                }

                is_empty = false;

                const val = @field(c, cnst);
                defer vals[val] = cnst;
                if (vals[val].len != 0) {
                    aliases = aliases ++ &[_]Alias{.{ .name = cnst, .target = vals[val] }};
                    continue;
                }
                code = code ++ std.fmt.comptimePrint(
                    \\        {s} = {},
                    \\
                , .{ cnst, val });
            }

            for (aliases) |alias| {
                code = code ++ std.fmt.comptimePrint(
                    \\        pub const {s} = @This().{s};
                    \\
                , .{ alias.name, alias.target });
            }

            if (is_empty) code = code ++
                \\        _,
                \\
            ;
        }
    }

    var args = std.process.args();
    _ = args.next();
    if (args.next()) |filename| {
        var out = try std.fs.cwd().createFileZ(filename, .{});
        defer out.close();
        try out.writeAll(code);
    } else {
        std.debug.print("{s}", .{code});
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
