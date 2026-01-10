const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");
const InputManager = @import("input/management.zig");
const Context = @import("context.zig");


const Matcher = union(enum){
    appid: []u8,
};

const Rule = union(enum) {
    float: void,
    workspace: Workspace.WS,
};

pub const WindowRule = struct {
    match: Matcher,
    rule: Rule,
};
