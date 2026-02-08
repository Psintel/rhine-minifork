const std = @import("std");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const wayland = @import("wayland");

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");

const Window = @import("window.zig");
const Output = @import("output.zig");
const Monitor = @import("output.zig");
const Seat = @import("seat.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");
const Tiler = @import("tiler.zig");
const Layouts = @import("layouts.zig");

const log = std.log;

signature: []u8,

pub fn init(ctx: *Context) !@This() {
    const display = ctx.child_env.get("WAYLAND_DISPLAY").?;

    const name = try std.fmt.allocPrint(ctx.gpa, "rhine-{s}", .{display});
    try ctx.child_env.put("HYPRLAND_INSTANCE_SIGNATURE", name);
    log.info("HYPRLAND_INSTANCE_SIGNATURE: {s}", .{name});

    const sockdirpath = try std.fmt.allocPrint(ctx.gpa, "hypr/{s}", .{name});
    defer ctx.gpa.free(sockdirpath);

    const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;

    var dir = try std.fs.openDirAbsolute(runtime, .{});
    defer dir.close();
    try dir.makePath(sockdirpath);

    var sd = try dir.openDir(sockdirpath, .{});
    defer sd.close();

    sd.deleteFile(".socket.sock") catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    return .{
        .signature = name,
    };
}

fn path(self: @This(), allocator: mem.Allocator) ![]u8 {
    // const sig = std.posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.InstanceNotFound;
    const sig = self.signature;
    const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;

    return std.fmt.allocPrint(allocator, "{s}/hypr/{s}/.socket.sock", .{ runtime, sig });
}

fn handlePlain(ctx: *Context, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    if (mem.order(u8, reader.buffered(), "/workspaces") == .eq) {
        var wsit = ctx.workspaces.iterator();
        while (wsit.next()) |_ws| {
            const ws = _ws.key_ptr.*;
            const ws_dat = _ws.value_ptr;
            const out = Output.byWorkspace(ctx, ws);
            const win_count = ws_dat.windows.count() + ws_dat.floating.count();

            if (out == null and win_count == 0) continue;

            const id = if (out) |o| o.getId() else null;

            try writer.print("workspace ID {0} ({0}) on monitor {1?}:\n", .{ ws + 1, id });
            try writer.print(
                \\     monitorID: {?}
                \\     windows: {}
                \\     hasfullscreen: 0
                \\
                \\
            ,
                .{ id, win_count },
            );
        }
    } else if (mem.order(u8, reader.buffered(), "/monitors") == .eq) {
        var outit = ctx.outs.iterator();
        while (outit.next()) |_out| {
            const out = _out.key_ptr.*;
            const out_data = _out.value_ptr;
            try writer.print("Monitor WL-1 (ID {0}):\n", .{out.getId()});
            try writer.print(
                \\     active workspace: {0} ({0})
                \\     focused: yes
                \\
                \\
            ,
                .{out_data.workspace + 1},
            );
        }

        if (ctx.outs.entries.len == 0) {
            try writer.print("Monitor WL-1 (ID 0):\n", .{});
            try writer.print(
                \\     active workspace: 0 (0)
                \\     focused: yeg
                \\
                \\
            ,
                .{},
            );
        }
    } else if (mem.eql(u8, try reader.takeDelimiter(' ') orelse return, "/dispatch")) {
        const word = try reader.takeDelimiter(' ') orelse return;
        if (mem.eql(u8, word, "workspace")) {
            const id_s = reader.buffered();
            const id = try std.fmt.parseInt(Workspace.WS, id_s, 0);

            if (ctx.last_active) |last| {
                try ctx.commands_queue.add(ctx.gpa, last, .{
                    .focusWorkspace = id - 1,
                });
            }

            try writer.print("ok", .{});
        }
    } else {
        try writer.print("don't know how to respond :(\n\n", .{});
        log.info("unknown ipc request {s}", .{reader.buffered()});
    }
    try writer.flush();
}

fn handleCon(serv: *net.Server, ctx: *Context) !void {
    const conn = try serv.accept();

    var buffer: [0x200]u8 = undefined;

    const stream = conn.stream;
    defer stream.close();
    var writer_obj = stream.writer(buffer[0..0x100]);
    var reader_obj = stream.reader(buffer[0x100..]);
    const writer = &writer_obj.interface;
    const reader: *std.Io.Reader = reader_obj.interface();

    while (reader.bufferedLen() == 0) {
        try reader.fillMore();
    }

    switch (try reader.peekByte()) {
        '/' => try handlePlain(ctx, reader, writer),
        else => {
            try writer.print("wtf bro yappin about?\n", .{});
            log.info("unknown IPC request start: {s}", .{reader.buffered()});
            // try ctx.events.seekTo(0);
            // _ = try ctx.events.write("HEY!");
        },
    }
    try writer.flush();
}

pub fn run(self: @This(), ctx: *Context) !void {
    var pathbuf: [std.posix.PATH_MAX]u8 = @splat(0);
    var bufalloc: std.heap.FixedBufferAllocator = .init(&pathbuf);
    const alloc = bufalloc.allocator();

    const sockpath = try path(self, alloc);

    const addr = try net.Address.initUnix(sockpath);
    var serv = try addr.listen(.{});
    defer serv.deinit();

    while (true) {
        handleCon(&serv, ctx) catch |e| {
            log.err("HyprIPC error: {}", .{e});
        };
    }
}

pub fn deinit(self: @This(), ctx: *Context) void {
    defer ctx.gpa.free(self.signature);

    var pathbuf: [std.posix.PATH_MAX]u8 = @splat(0);
    var bufalloc: std.heap.FixedBufferAllocator = .init(&pathbuf);
    const alloc = bufalloc.allocator();

    const sockpath = path(self, alloc) catch return;

    std.fs.deleteFileAbsolute(sockpath) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return,
    };
}
