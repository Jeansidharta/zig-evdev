const std = @import("std");
const t = std.testing;

const Event = @import("Event");

test "Type.getName" {
    var ty: Event.Type = undefined;

    ty = .syn;
    try t.expectEqualStrings(ty.getName(), "EV_SYN");

    ty = .ff_status;
    try t.expectEqualStrings(ty.getName(), "EV_FF_STATUS");
}

test "Type.CodeType" {
    try t.expectEqual(Event.Type.key.CodeType(), Event.Code.KEY);
    try t.expectEqual(Event.Type.msc.CodeType(), Event.Code.MSC);
}

test "Code.getName" {
    var c: Event.Code = undefined;

    c = .{ .syn = .SYN_REPORT };
    try t.expectEqualStrings(c.getName().?, "SYN_REPORT");

    c = Event.Code.PWR.new(0).intoCode();
    try t.expectEqual(c.getName(), null);
}

test "Code.getType" {
    try t.expectEqual((Event.Code{ .rel = .REL_X }).getType(), Event.Type.rel);
    try t.expectEqual((Event.Code{ .led = .LED_CAPSL }).getType(), Event.Type.led);
}

test "Code.XXX.intoCode" {
    try t.expectEqual(Event.Code.KEY.KEY_1.intoCode(), Event.Code{ .key = .KEY_1 });
    try t.expectEqual(Event.Code.PWR.new(0).intoCode(), Event.Code.new(.pwr, 0));
}
