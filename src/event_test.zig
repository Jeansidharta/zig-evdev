const std = @import("std");
const t = std.testing;

const Event = @import("Event");

test "Type.getName" {
    var ty: Event.Type = undefined;

    ty = .SYN;
    try t.expectEqualStrings(ty.getName(), "EV_SYN");

    ty = .FF_STATUS;
    try t.expectEqualStrings(ty.getName(), "EV_FF_STATUS");
}

test "Type.CodeType" {
    try t.expectEqual(Event.Type.KEY.CodeType(), Event.Code.KEYCODE);
    try t.expectEqual(Event.Type.MSC.CodeType(), Event.Code.MSCCODE);
}

test "Code.getName" {
    var c: Event.Code = undefined;

    c = .{ .SYN = .SYN_REPORT };
    try t.expectEqualStrings(c.getName().?, "SYN_REPORT");

    c = Event.Code.PWRCODE.new(0).intoCode();
    try t.expectEqual(c.getName(), null);
}

test "Code.getType" {
    try t.expectEqual((Event.Code{ .REL = .REL_X }).getType(), Event.Type.REL);
    try t.expectEqual((Event.Code{ .LED = .LED_CAPSL }).getType(), Event.Type.LED);
}

test "Code.XXX.intoCode" {
    try t.expectEqual(Event.Code.KEYCODE.KEY_1.intoCode(), Event.Code{ .KEY = .KEY_1 });
    try t.expectEqual(Event.Code.PWRCODE.new(0).intoCode(), Event.Code.new(.PWR, 0));
}
