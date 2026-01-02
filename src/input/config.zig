const std = @import("std");
const meta = std.meta;
const Type = std.builtin.Type;

touchpad: struct {
    natural_scroll: bool,
}
