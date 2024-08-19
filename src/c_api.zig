const c = @cImport({
    @cInclude("errno.h");
    @cInclude("string.h");
});
pub const EAGAIN = c.EAGAIN;
pub const strerror = c.strerror;

pub usingnamespace @cImport({
    @cInclude("libevdev/libevdev.h");
    @cInclude("libevdev/libevdev-uinput.h");
});
