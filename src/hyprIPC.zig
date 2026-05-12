const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const net = std.Io.net;
const posix = std.posix;
const Io = std.Io;
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
const Config = @import("config.zig");
const commands = @import("commands.zig");

const log = std.log;

signature: []u8,

pub fn init(ctx: *Context) !@This() {
    const display = ctx.child_env.get("WAYLAND_DISPLAY").?;

    const name = try std.fmt.allocPrint(ctx.gpa, "rhine-{s}", .{display});
    try ctx.child_env.put("HYPRLAND_INSTANCE_SIGNATURE", name);
    log.info("HYPRLAND_INSTANCE_SIGNATURE: {s}", .{name});

    const sockdirpath = try std.fmt.allocPrint(ctx.gpa, "hypr/{s}", .{name});
    defer ctx.gpa.free(sockdirpath);

    const runtime = ctx.child_env.get("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;

    var dir = try std.Io.Dir.openDirAbsolute(ctx.io, runtime, .{});
    defer dir.close(ctx.io);
    try dir.createDirPath(ctx.io, sockdirpath);

    var sd = try dir.openDir(ctx.io, sockdirpath, .{});
    defer sd.close(ctx.io);

    sd.deleteFile(ctx.io, ".socket.sock") catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    sd.deleteFile(ctx.io, ".socket2.sock") catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    return .{
        .signature = name,
    };
}

fn sock1(self: @This(), buffer: []u8, env: *std.process.Environ.Map) ![]u8 {
    const sig = self.signature;
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;
    return std.fmt.bufPrint(buffer, "{s}/hypr/{s}/.socket.sock", .{ runtime, sig });
}

fn sock2(self: @This(), buffer: []u8, env: *std.process.Environ.Map) ![]u8 {
    const sig = self.signature;
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;

    return std.fmt.bufPrint(buffer, "{s}/hypr/{s}/.socket2.sock", .{ runtime, sig });
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
            const wl_data = ctx.wl_outs.get(out_data.wl_out orelse continue) orelse continue;
            try writer.print("Monitor {1?s} (ID {0}):\n", .{ out.getId(), wl_data.name });
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
                \\     focused: yes
                \\
                \\
            ,
                .{},
            );
        }
    } else if (mem.order(u8, reader.buffered(), "/clients") == .eq) {
        var win_it = ctx.wins.iterator();
        while (win_it.next()) |_win| {
            const win = _win.key_ptr.*;
            const win_dat = _win.value_ptr;
            const pos = win_dat.pos.current(ctx.anims, ctx.io);
            const size = win_dat.size;

            const ws = Workspace.byWindow(ctx, win);

            try writer.print("Window {} -> {?s}:\n", .{ win.getId(), win_dat.title });
            try writer.print(
                \\    mapped: 1
                \\    hidden: 0
                \\    at: {0}, {1}
                \\    size: {2}, {3},
                \\    workspace: {4?} ({4?})
                \\    class: {5?s}
                \\
                \\
            ,
                .{ pos[0], pos[1], size[0], size[1], ws, win_dat.app_id },
            );
        }
    } else if (mem.startsWith(u8, reader.buffered(), "/dispatch")) {
        _ = try reader.discardDelimiterInclusive(' ');
        const word = try reader.takeDelimiter(' ') orelse return;
        if (mem.eql(u8, word, "workspace")) {
            const id_s = reader.buffered();
            const id = try std.fmt.parseInt(Workspace.WS, id_s, 0);

            if (ctx.last_active) |last| {
                try ctx.commands_queue.add(ctx.gpa, ctx.io, last, .{
                    .focusWorkspace = .{ .Abs = id - 1 },
                });
            }
            try writer.print("ok", .{});
        }
    } else if (mem.startsWith(u8, reader.buffered(), "/rhine")) {
        _ = try reader.discardDelimiterInclusive(' ');
        try handleCmd(ctx, reader.buffered());
        try writer.print("ok", .{});
    } else {
        try writer.print("don't know how to respond :(\n\n", .{});
        log.info("unknown ipc request {s}", .{reader.buffered()});
    }
    try writer.flush();
}

fn handleCmd(ctx: *Context, word: []const u8) !void {
    log.info("trying to parse command: {s}", .{word});
    var r = std.Io.Reader.fixed(word);
    const e = try Config.parseEntry(ctx.gpa, &r);
    defer e.deinit(ctx.gpa);
    var iter = e.iterate();
    const c = try commands.Command.fromArg(&iter);

    if (ctx.last_active) |s|
        try ctx.commands_queue.add(ctx.gpa, ctx.io, s, c);
}

fn handleCon(serv: *net.Server, ctx: *Context) !void {
    const stream = try serv.accept(ctx.io);
    defer stream.close(ctx.io);
    var buffer: [0x500]u8 = undefined;

    var writer_obj = stream.writer(ctx.io, buffer[0x100..]);
    var reader_obj = stream.reader(ctx.io, buffer[0..0x100]);
    const writer = &writer_obj.interface;
    const reader = &reader_obj.interface;

    while (reader.bufferedLen() == 0) {
        try reader.fillMore();
    }

    switch (try reader.peekByte()) {
        '/' => try handlePlain(ctx, reader, writer),
        else => {
            try writer.print("wtf bro yappin about?\n", .{});
            log.info("unknown IPC request start: {s}", .{reader.buffered()});
        },
    }
    try writer.flush();
    _ = try ctx.events.writeStreamingAll(ctx.io, "HEY!");
}

pub fn sock1Worker(self: @This(), ctx: *Context) !void {
    var buffer: [posix.PATH_MAX]u8 = undefined;
    const sockpath = try sock1(self, &buffer, ctx.child_env);

    const addr: net.UnixAddress = try .init(sockpath);
    var serv = try addr.listen(ctx.io, .{});
    defer serv.deinit(ctx.io);

    while (true) {
        handleCon(&serv, ctx) catch |e| {
            log.err("HyprIPC error: {}", .{e});
        };
    }
}

pub const HyprEvent = union(enum) {
    const WS = Workspace.WS;
    const Out = Output.Wl;
    const Win = Window;
    const Trans = utils.Transaction;
    const Unimpl = union{};

    workspace: WS,
    workspacev2: WS,
    focusedmon: struct { Out, WS },
    focusedmonv2: struct { Out, WS },
    activewindow: Win,
    activewindowv2: u32,
    fullscreen: Trans,
    monitorremoved: Out,
    monitorremovedv2: Out,
    monitoradded: Out,
    monitoraddedv2: Out,
    createworkspace: WS,
    createworkspacev2: WS,
    destroyworkspace: WS,
    destroyworkspacev2: WS,
    moveworkspace: struct { WS, Out },
    moveworkspacev2: struct { WS, Out },
    renameworkspace: WS,
    activespecial: struct { WS, Out },
    activespecialv2: struct { WS, Out },
    activelayout: Unimpl,
    openwindow: struct { Win, WS },
    closewindow: struct { Win },
    kill: struct { Win },
    movewindow: struct { Win, WS },
    movewindowv2: struct { Win, WS },
    openlayer: Unimpl,
    closelayer: Unimpl,
    submap: Unimpl,
    changefloatingmode: struct { Win, Trans },
    urgent: Unimpl,
    screencast: Unimpl,
    screencastv2: Unimpl,
    windowtitle: Win,
    windowtitlev2: Win,
    togglegroup: Unimpl,
    moveintogroup: Unimpl,
    moveoutofgroup: Unimpl,
    ignoregrouplock: Unimpl,
    lockgroups: Unimpl,
    configreloaded: void,
    pin: Unimpl,
    minimized: Unimpl,
    bell: Unimpl,

    pub fn format(self: @This(), w: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            else => {
                try w.print("", .{});
            },
        }
    }
};
pub const HyprQueue = std.Io.Queue(HyprEvent);

pub fn sock2Worker(self: @This(), io: std.Io, ctx: *Context, queue: *HyprQueue) !void {
    var buffer: [posix.PATH_MAX]u8 = undefined;
    const sockpath = try sock2(self, &buffer, ctx.child_env);

    const addr: net.UnixAddress = try .init(sockpath);
    var serv = try addr.listen(io, .{});
    defer serv.deinit(io);

    var clients: std.ArrayList(net.Stream) = .empty;
    defer clients.deinit(ctx.gpa);
    defer for (clients.items) |s| s.close(io);
    const SelectT = union(enum) {
        event: (Io.QueueClosedError || Io.Cancelable)!HyprEvent,
        connection: net.Server.AcceptError!net.Stream,
    };
    var selbuf: [2]SelectT = undefined;
    var select: Io.Select(SelectT) = .init(io, &selbuf);
    defer select.cancelDiscard();

    select.async(.connection, net.Server.accept, .{ &serv, io });
    select.async(.event, HyprQueue.getOne, .{ queue, io });

    while (select.await()) |sel| switch (sel) {
        .connection => |_con| {
            const con = try _con;
            try clients.append(ctx.gpa, con);
            select.async(.connection, net.Server.accept, .{ &serv, io });
        },
        .event => |_ev| {
            const ev = _ev catch |e| switch (e) {
                error.Closed => break,
                else => return e,
            };
            var i: usize = 0;
            while (i < clients.items.len) {
                const cli = clients.items[i];
                var buff: [100]u8 = undefined;
                var writer = cli.writer(io, &buff);
                var iface = &writer.interface;
                iface.print("{s}>>{f}\n", .{ @tagName(meta.activeTag(ev)), ev }) catch {
                    clients.swapRemove(i).close(io);
                    continue;
                };

                iface.flush() catch {
                    clients.swapRemove(i).close(io);
                    continue;
                };

                i += 1;
            }
            select.async(.event, HyprQueue.getOne, .{ queue, io });
        },
    } else |e| return e;
}

pub fn deinit(self: @This(), ctx: *Context) void {
    defer ctx.gpa.free(self.signature);

    var pathbuf: [std.posix.PATH_MAX]u8 = @splat(0);
    const sockpath = sock1(self, &pathbuf, ctx.child_env) catch return;

    std.Io.Dir.deleteFileAbsolute(ctx.io, sockpath) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return,
    };
}
