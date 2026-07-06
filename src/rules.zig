const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = tributary.utils;
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");
const Context = @import("context.zig");
const Config = tributary.Config;
const globbing = tributary.globbing;

const Matcher = union(enum) {
    appid: []const u8,

    pub fn match(self: @This(), appid: []const u8) bool {
        return globbing.match(self.appid, appid);
    }
};

const Rule = union(enum) {
    float: bool,
    workspace: Workspace.WS,
};

pub const WindowRule = struct {
    match: Matcher,
    rule: Rule,

    pub fn parse(args: *Config.Entry.Iterator) !@This() {
        const match = try args.nextAssume();
        const rule = try args.parseT(Rule);

        return .{
            .match = .{ .appid = match },
            .rule = rule,
        };
    }

    // pub fn apply(self: @This(), win: *Window) void {
    //     if (!self.match.match(win.app_id)) return;

    //     switch(self.rule) {
    //         .float => win.float = true,
    //         .workspace => win.
    //     }
    // }
};
