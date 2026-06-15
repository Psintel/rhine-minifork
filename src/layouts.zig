// these enumerate all posible layouts from which we generate tilers
const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const meta = std.meta;
const fmt = std.fmt;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = tributary.utils;
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Config = tributary.Config;
const log = std.log.scoped(.Layout);

const layouts = .{
    .bsp = @import("layouts/bsp.zig"),
    // .monocle = @import("layouts/monocle.zig"),
};

comptime {
    for (meta.fieldNames(Layout)) |lname| {
        const layout = @field(layouts, lname);

        if (!@hasField(layout, "tiler"))
            @compileError(fmt.comptimePrint("layout {s} is a field \"tiler\"", .{lname}));
    }
}

pub const LayoutMap = std.AutoHashMapUnmanaged(Tiler, *anyopaque);
pub const LayoutType = meta.FieldEnum(@TypeOf(layouts));

pub const Layout = layout: {
    const builtin = std.builtin;

    const fs = meta.fields(@TypeOf(layouts));
    const names = meta.fieldNames(@TypeOf(layouts));
    var types: [fs.len]type = undefined;
    var attrs: [fs.len]builtin.Type.UnionField.Attributes = undefined;

    for (fs, &types, &attrs) |f, *t, *a| {
        t.* = @field(layouts, f.name);
        a.* = .{ .@"align" = meta.alignment(f.type) };
    }
    break :layout @Union(.auto, LayoutType, names, &types, &attrs);
};

pub fn parseCommand(args: *Config.Entry.Iterator) !struct { LayoutType, Tiler.Command } {
    const layout = meta.stringToEnum(LayoutType, try args.nextAssume()) orelse return error.InvalidLayout;

    switch (layout) {
        inline else => |l| {
            const layout_impl = @field(layouts, @tagName(l));
            if (!@hasDecl(layout_impl, "Command")) return error.LayoutDoesNotSupportCommands;
            const Command = layout_impl.Command;
            if (@hasDecl(Command, "parse"))
                return Command.parse(args)
            else if (meta.stringToEnum(Command, try args.nextAssume())) |cmd|
                return .{ l, .{ .command = @intFromEnum(cmd), .payload = null } }
            else
                return error.InvalidCommand;
        },
    }
}

fn create(comptime lay: LayoutType) @field(layouts, @tagName(lay)) {
    const name = @tagName(lay);
    const T = @field(layouts, name);

    if (@hasDecl(T, "init")) {
        return T.init();
    }

    return T{};
}

pub fn new(gpa: mem.Allocator, _lay: LayoutType) !Tiler {
    log.info("creating new layout {}", .{_lay});
    switch (_lay) {
        inline else => |lay| {
            const l = try gpa.create(@field(layouts, @tagName(lay)));
            errdefer gpa.destroy(l);
            l.* = create(lay);
            const t = l.tiler.get(lay);
            return t;
        },
    }
}

pub fn delete(gpa: mem.Allocator, tile: Tiler) void {
    const ptr = tile.context orelse return;
    switch (tile.tag) {
        inline else => |t| {
            const T = @field(layouts, @tagName(t));
            const v: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "deinit")) {
                v.deinit(gpa);
            }
            gpa.destroy(v);
        },
    }
}
