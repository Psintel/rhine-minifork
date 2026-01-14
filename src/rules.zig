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
const Config = @import("config.zig");

const Matcher = union(enum) {
    appid: []const u8,

    pub fn match(self: @This(), appid: []const u8) bool {
        return std.mem.eql(u8, self.appid, appid);
    }
};

const Rule = union(enum) {
    float: void,
    workspace: Workspace.WS,
};

pub const WindowRule = struct {
    match: Matcher,
    rule: Rule,

    pub fn fromEntry(entry: Config.Entry) !@This() {
        if (entry.args.len != 2) return error.ParseError;

        const match = entry.args[0];
        const rules = entry.args[1];

        var ruleit = std.mem.tokenizeScalar(u8, rules, ' ');
        const rtype = std.meta.stringToEnum(
            std.meta.Tag(Rule),
            ruleit.next() orelse return error.ParseError,
        ) orelse return error.WrongKey;

        const rule: Rule = switch (rtype) {
            .float => .{ .float = {} },
            .workspace => ws: {
                const wss = ruleit.next() orelse return error.ParseError;
                const ws = std.fmt.parseInt(Workspace.WS, wss, 0) catch return error.ParseError;
                break :ws .{ .workspace = ws };
            },
        };

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
