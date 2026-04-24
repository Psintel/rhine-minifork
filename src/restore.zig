const std = @import("std");
const wayland = @import("wayland");

const rwm = wayland.client.river;

const Workspace = @import("workspace.zig");
const Context = @import("context.zig");

pub const Data = packed struct {
    workspace: Workspace.WS,
};

pub const Id = [32]u8;

relations: std.AutoArrayHashMapUnmanaged(Id, Data),

pub fn deserialize(reader: *std.Io.Reader, gpa: std.mem.Allocator) !@This() {
    var out: @This() = .{
        .relations = .empty,
    };

    while (reader.takeArray(32)) |arr| {
        var id: Id = @splat(0);
        @memcpy(&id, arr);

        const data = try reader.takeStruct(Data, .native);
        try out.relations.put(gpa, id, data);
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return e,
    }

    return out;
}

pub fn serialize(self: @This(), writer: *std.Io.Writer) !void {
    var iter = self.relations.iterator();

    while(iter.next()) |kv| {
        const id = kv.key_ptr.*;
        const data = kv.value_ptr.*;

        try writer.writeAll(&id);
        try writer.writeStruct(data, .native);
    }

    try writer.flush();
}

pub fn fromCtx(ctx: *const Context) !@This() {
    var out: @This() = .{
        .relations = .empty,
    };
    var iter = ctx.wins.iterator();

    while (iter.next()) |kv| {
        const win = kv.key_ptr.*;
        const win_data = kv.value_ptr.*;

        const ws = Workspace.byWindow(ctx, win) orelse continue;

        const data: Data = .{
            .workspace = ws,
        };

        try out.relations.put(ctx.gpa, win_data.identifier, data);
    }

    return out;
}

pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    self.relations.deinit(alloc);
}
