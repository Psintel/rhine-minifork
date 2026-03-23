// these enumerate all posible layouts from which we generate tilers
const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Config = @import("config.zig");

const layouts = .{
    .bsp = @import("bsp.zig"),
};

var storageMap: LayoutMap = .empty;

pub const LayoutMap = std.AutoHashMapUnmanaged(Tiler, *Layout);
pub const LayoutType = meta.FieldEnum(@TypeOf(layouts));

pub const Layout = layout: {
    const builtin = std.builtin;

    const fs = meta.fields(@TypeOf(layouts));
    var es: [fs.len]builtin.Type.UnionField = undefined;

    for (fs, &es) |f, *e| {
        e.* = .{
            .name = f.name,
            .type = @field(layouts, f.name),
            .alignment = meta.alignment(f.type),
        };
    }

    const un: builtin.Type.Union = .{
        .tag_type = LayoutType,
        .decls = &.{},
        .layout = .auto,
        .fields = &es,
    };

    const retT = @Type(builtin.Type{ .@"union" = un });

    break :layout retT;
};

pub fn parseCommand(args: *Config.Entry.Iterator) !struct{ LayoutType, Tiler.Command} {
    const layout = meta.stringToEnum(LayoutType, try args.nextAssume()) orelse return error.InvalidLayout;

    switch (layout) {
        inline else => |l| {
            const layout_impl = @field(layouts, @tagName(l));
            if (!@hasDecl(layout_impl, "Command")) return error.LayoutDoesNotSupportCommands;
            const Command = layout_impl.Command;
            if (@hasDecl(Command, "parse"))
                return Command.parse(args)
            else if (meta.stringToEnum(Command, try args.nextAssume())) |cmd|
                return .{l, .{ .command = @intFromEnum(cmd), .payload = null }}
            else
                return error.InvalidCommand;
        },
    }
}

fn create(lay: LayoutType) Layout {
    const name = @tagName(lay);
    const T = @field(layouts, name);

    if (@hasDecl(T, "init")) {
        return @unionInit(Layout, name, T.init());
    }

    return @unionInit(Layout, name, T{});
}

pub fn new(gpa: mem.Allocator, lay: LayoutType) !Tiler {
    const l = try gpa.create(Layout);
    errdefer gpa.destroy(l);

    l.* = create(lay);
    const t = @field(l, @tagName(lay)).tiler.get(lay);

    try storageMap.put(gpa, t, l);

    return t;
}

pub fn delete(gpa: mem.Allocator, tile: Tiler) void {
    const ptr = storageMap.get(tile).?;
    switch (ptr.*) {
        inline else => |v| {
            const T = @TypeOf(v);
            if (@hasDecl(T, "deinit")) {
                v.deinit(gpa);
            }
        },
    }
    _ = storageMap.remove(tile);
    if (storageMap.size == 0) storageMap.clearAndFree(gpa);
    gpa.destroy(ptr);
}
