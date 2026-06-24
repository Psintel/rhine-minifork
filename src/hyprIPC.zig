const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const meta = std.meta;
const net = std.Io.net;
const posix = std.posix;
const fmt = std.fmt;
const Io = std.Io;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = tributary.utils;

const Window = @import("window.zig");
const Output = @import("output.zig");
const Monitor = @import("output.zig");
const Seat = @import("seat.zig");
const Context = @import("context.zig");
const Workspace = @import("workspace.zig");
const RhineWs = Workspace;
const Tiler = @import("tiler.zig");
const Layouts = @import("layouts.zig");
const Config = tributary.Config;
const Animations = @import("animations.zig");
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

const Datas = struct {
    pub const Workspace = struct {
        id: i32,
        name: []const u8,
        monitor: []const u8,
        monitorID: u32,
        windows: usize,
        hasfullscreen: bool = false,
        ispersistent: bool = false,
        tiledLayout: Layouts.LayoutType,

        pub fn populate(ctx: *Context, ws: RhineWs.WS, arena: mem.Allocator) !?@This() {
            const ws_dat = ctx.workspaces.get(ws) orelse return null;
            const out = Output.byWorkspace(ctx, ws);
            const win_count = ws_dat.windows.count() + ws_dat.floating.count();

            const id = if (out) |o| ctx.outs.getIndex(o) else null;
            const mname = name: {
                const o = out orelse break :name null;
                const od = ctx.outs.get(o) orelse break :name null;
                const g = od.wl_out orelse break :name null;
                const wlo = ctx.wl_outs.get(g) orelse break :name null;
                break :name wlo.name;
            };

            return .{
                .id = ws + 1,
                .name = try fmt.allocPrint(arena, "{}", .{ws}),
                .monitor = mname orelse "",
                .monitorID = @intCast(id orelse 0),
                .windows = win_count,
                .tiledLayout = ws_dat.tiler.tag,
            };
        }

        pub fn format(ws: @This(), writer: *Io.Writer) !void {
            try writer.print("workspace ID {} ({s}) on monitor {s}:\n", .{ ws.id, ws.name, ws.monitor });
            try writer.print("\tmonitorID: {}\n", .{ws.monitorID});
            try writer.print("\twindows: {}\n", .{ws.windows});
            try writer.print("\thasfullscreen: {}\n", .{@intFromBool(ws.hasfullscreen)});
            try writer.print("\tispersistent: {}\n", .{@intFromBool(ws.ispersistent)});
            try writer.print("\ttiledLayout: {?s}\n", .{std.enums.tagName(Layouts.LayoutType, ws.tiledLayout)});
        }
    };

    pub const SubWS = struct {
        id: i32,
        name: []const u8,
        pub fn format(ws: @This(), writer: *Io.Writer) !void {
            try writer.print("{} ({s})", .{ ws.id, ws.name });
        }
    };

    pub const Monitor = struct {
        id: u32,
        name: ?[]const u8,
        description: ?[]const u8,
        make: ?[]const u8,
        model: ?[]const u8,
        serial: ?[]const u8,
        width: i32,
        height: i32,
        physicalWidth: i32,
        physicalHeight: i32,
        refreshRate: i32,
        x: i32,
        y: i32,
        activeWorkspace: SubWS,
        specialWorkspace: SubWS,
        reserved: struct { i32, i32, i32, i32 },
        scale: f32,
        transform: i32,
        focused: bool,
        disabled: bool = false,

        pub fn format(mon: @This(), writer: *Io.Writer) !void {
            try writer.print("Monitor {?s} (ID {}):\n", .{ mon.name, mon.id });
            try writer.print("\t{}x{}@{} at {}x{}\n", .{ mon.width, mon.height, mon.refreshRate, mon.x, mon.y });
            try writer.print("\tdescription: {?s}\n", .{mon.description});
            try writer.print("\tmake: {?s}\n", .{mon.make});
            try writer.print("\tmodel: {?s}\n", .{mon.model});
            try writer.print("\tphysical size (mm): {}x{}\n", .{ mon.physicalWidth, mon.physicalHeight });
            try writer.print("\tserial: {?s}\n", .{mon.serial});
            try writer.print("\tactive workspace: {f}\n", .{mon.activeWorkspace});
            try writer.print("\tspecial workspace: {f}\n", .{mon.specialWorkspace});
            try writer.print("\treserved: {} {} {} {}\n", mon.reserved);
            try writer.print("\tscale: {}\n", .{mon.scale});
            try writer.print("\ttransform: {}\n", .{mon.transform});
            try writer.print("\tfocused: {s}\n", .{if (mon.focused) "yes" else "no"});
            try writer.print("\tdpmsStatus: 1\n", .{});
            try writer.print("\tvrr: false\n", .{});
            try writer.print("\tsolitary: 0\n", .{});
            try writer.print("\tsolitaryBlockedBy: windowed mode,missing candidate\n", .{});
            try writer.print("\tactivelyTearing: false\n", .{});
            try writer.print("\ttearingBlockedBy: next frame is not torn,user settings,missing candidate\n", .{});
            try writer.print("\tdirectScanoutTo: 0\n", .{});
            try writer.print("\tdirectScanoutBlockedBy: user settings,software renders/cursors,missing candidate\n", .{});
            try writer.print("\tdisabled: false\n", .{});
            try writer.print("\tcurrentFormat: XRGB8888\n", .{});
            try writer.print("\tmirrorOf: none\n", .{});
            try writer.print("\tavailableModes: \n", .{});
            try writer.print("\tcolorManagementPreset: srgb\n", .{});
            try writer.print("\tsdrBrightness: 1.00\n", .{});
            try writer.print("\tsdrSaturation: 1.00\n", .{});
            try writer.print("\tsdrMinLuminance: 0.20\n", .{});
            try writer.print("\tsdrMaxLuminance: 80\n", .{});
        }
    };

    pub const Client = struct {
        address: []const u8,
        mapped: bool,
        hidden: bool = false,
        at: struct { i32, i32 },
        size: struct { i32, i32 },
        workspace: SubWS,
        floating: bool,
        monitor: u32,
        class: ?[]const u8,
        title: ?[]const u8,
        pid: ?i32,
        fullscreen: u1,
        swallowing: u32 = 0,
        stableId: []const u8,

        pub fn populate(ctx: *Context, win: *rwm.WindowV1, arena: mem.Allocator) !?@This() {
            const win_dat = ctx.wins.get(win) orelse return null;
            const man_dat = ctx.manage_states.get(win) orelse return null;
            const pos = win_dat.pos.current(ctx.anims, ctx.io);
            const size = win_dat.size;
            const ws = RhineWs.byWindow(ctx, win) orelse return null;
            const out = Output.byWorkspace(ctx, ws);

            return .{
                .address = try fmt.allocPrint(arena, "0x{x}", .{win.getId()}),
                .mapped = man_dat.show,
                .at = .{ pos[0], pos[1] },
                .size = .{ size[0], size[1] },
                .workspace = .{
                    .id = ws + 1,
                    .name = try fmt.allocPrint(arena, "{}", .{ws}),
                },
                .floating = win_dat.float,
                .monitor = if (out) |o| @intCast(ctx.outs.getIndex(o).?) else 0,
                .class = win_dat.app_id,
                .title = win_dat.title,
                .pid = win_dat.unreliable_pid,
                .fullscreen = @intFromBool(win_dat.fullscreen.isOn()),
                .stableId = &win_dat.identifier,
            };
        }

        pub fn format(cli: @This(), writer: *Io.Writer) !void {
            try writer.print("Window {X} -> {?s}:\n", .{ cli.address, cli.title });
            try writer.print("\tmapped: {}\n", .{@intFromBool(cli.mapped)});
            try writer.print("\thidden: {}\n", .{@intFromBool(cli.hidden)});
            try writer.print("\tat: {}, {}\n", cli.at);
            try writer.print("\tsize: {}, {}\n", cli.size);
            try writer.print("\tworkspace: {f}\n", .{cli.workspace});
            try writer.print("\tfloating: {}\n", .{@intFromBool(cli.floating)});
            try writer.print("\tmonitor: {}\n", .{cli.monitor});
            try writer.print("\tclass: {?s}\n", .{cli.class});
            try writer.print("\ttitle: {?s}\n", .{cli.title});
            try writer.print("\tpid: {?}\n", .{cli.pid});
            try writer.print("\txwayland: {}\n", .{0});
            try writer.print("\tpinned: {}\n", .{0});
            try writer.print("\tfullscreen: {}\n", .{cli.fullscreen});
            try writer.print("\tswallowing: {}\n", .{cli.swallowing});
            try writer.print("\tstableID: {s}\n", .{cli.stableId});
        }
    };
};

fn handle(ctx: *Context, reader: *Io.Reader, json: bool, writer: *Io.Writer) !void {
    var json_str: std.json.Stringify = .{
        .writer = writer,
        .options = .{
            .whitespace = .indent_tab,
            .emit_null_optional_fields = true,
        },
    };
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (mem.startsWith(u8, reader.buffered(), "workspaces")) {
        if (json) try json_str.beginArray();
        for (ctx.workspaces.keys()) |ws| {
            const ws_obj = try Datas.Workspace.populate(ctx, ws, alloc) orelse continue;

            if (json) {
                try json_str.write(ws_obj);
            } else {
                try writer.print("{f}\n", .{ws_obj});
            }
        }
        if (json) try json_str.endArray();
    } else if (mem.startsWith(u8, reader.buffered(), "monitors")) {
        var outit = ctx.outs.iterator();
        if (json) try json_str.beginArray();
        while (outit.next()) |_out| {
            const out = _out.key_ptr.*;
            const out_data = _out.value_ptr;
            const wl_data = ctx.wl_outs.get(out_data.wl_out orelse continue) orelse continue;

            // best guess for monitor scale :D
            const scale: f32 = @reduce(.Add, utils.int2Float(wl_data.mode.dim) / utils.int2Float(out_data.size.?)) / 2;

            var focused = false;
            for (ctx.seats.keys()) |s| {
                if (Output.bySeat(ctx, s) == out) focused = true;
            }

            const out_obj: Datas.Monitor = .{
                .id = @intCast(ctx.outs.getIndex(out).?),
                .name = wl_data.name,
                .description = wl_data.description,
                .make = wl_data.make,
                .model = wl_data.model,
                .serial = "",
                .width = wl_data.mode.dim[0],
                .height = wl_data.mode.dim[1],
                .physicalWidth = wl_data.geometry.pdim[0],
                .physicalHeight = wl_data.geometry.pdim[1],
                .refreshRate = wl_data.mode.refresh,
                .x = out_data.position.?[0],
                .y = out_data.position.?[1],
                .activeWorkspace = .{
                    .id = out_data.workspace + 1,
                    .name = try fmt.allocPrint(alloc, "{}", .{out_data.workspace}),
                },
                .specialWorkspace = if (out_data.overlay) |ov| .{
                    .id = ov + 1,
                    .name = try fmt.allocPrint(alloc, "{}", .{ov}),
                } else .{ .id = 0, .name = "" },
                .reserved = .{ 0, 0, 0, 0 },
                .scale = scale,
                .focused = focused,
                .transform = @intFromEnum(wl_data.geometry.trafo),
            };

            if (json) {
                try json_str.write(out_obj);
            } else {
                try writer.print("{f}\n", .{out_obj});
            }
        }
        if (json) try json_str.endArray();
    } else if (mem.startsWith(u8, reader.buffered(), "clients")) {
        if (json) try json_str.beginArray();
        for (ctx.wins.keys()) |win| {
            const cli_obj = try Datas.Client.populate(ctx, win, alloc) orelse continue;
            if (json)
                try json_str.write(cli_obj)
            else
                try writer.print("{f}\n", .{cli_obj});
        }
        if (json) try json_str.endArray();
    } else if (mem.startsWith(u8, reader.buffered(), "activewindow")) {
        const seat = ctx.last_active orelse return;
        const seat_data = ctx.seats.get(seat) orelse return;
        const active = seat_data.focus orelse return;

        const cli_obj = try Datas.Client.populate(ctx, active, alloc) orelse return;

        if (json)
            try json_str.write(cli_obj)
        else
            try writer.print("{f}\n", .{cli_obj});
    } else if (mem.startsWith(u8, reader.buffered(), "activeworkspace")) {
        const seat = ctx.last_active orelse return;
        const ws = Workspace.bySeat(ctx, seat) orelse return;

        const cli_obj = try Datas.Workspace.populate(ctx, ws, alloc) orelse return;

        if (json)
            try json_str.write(cli_obj)
        else
            try writer.print("{f}\n", .{cli_obj});
    } else if (mem.startsWith(u8, reader.buffered(), "workspacerules")) {
        if (json)
            try json_str.write(&.{})
        else
            try writer.print("\n", .{});
    } else if (mem.startsWith(u8, reader.buffered(), "dispatch")) {
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
    } else if (mem.startsWith(u8, reader.buffered(), "rhine")) {
        _ = try reader.discardDelimiterInclusive(' ');
        try handleCmd(ctx, reader.buffered());
        try writer.print("ok", .{});
    } else {
        if (json)
            try json_str.write(.{})
        else
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
    const c = try e.parseT(commands.Command);

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
    errdefer log.info("unknown IPC request: {s}", .{reader.buffered()});

    const _j = reader.takeDelimiter('/') catch |e| switch (e) {
        error.StreamTooLong => return error.Invalid,
        error.ReadFailed => return e,
    } orelse return error.Invalid;

    const j = if (mem.eql(u8, _j, "")) false else if (mem.eql(u8, _j, "j")) true else return error.Invalid;

    try handle(ctx, reader, j, writer);

    try writer.flush();
    _ = try ctx.events.writeStreamingAll(ctx.io, "HEY!");
}

pub fn sock1Worker(self: @This(), ctx: *Context) !void {
    var buffer: [posix.PATH_MAX]u8 = undefined;
    const sockpath = try sock1(self, &buffer, ctx.child_env);

    const addr: net.UnixAddress = try .init(sockpath);
    var serv = try addr.listen(ctx.io, .{});
    defer serv.deinit(ctx.io);

    // const TimeoutU = union(enum) {
    //     con: @typeInfo(@TypeOf(handleCon)).@"fn".return_type.?,
    //     timeout: error{Canceled}!void,
    // };
    // var buf: [2]TimeoutU = undefined;

    while (true) {
        // var select: Io.Select(TimeoutU) = .init(ctx.io, &buf);
        // defer select.cancelDiscard();
        // try select.concurrent(.con, handleCon, .{ &serv, ctx });
        // try select.concurrent(.timeout, Io.sleep, .{ ctx.io, Io.Duration.fromSeconds(5), .awake });

        // switch (try select.await()) {
        //     .timeout => {},
        //     .con => |r| {
        //         r catch |e| log.err("HyprIPC error: {}", .{e});
        //     },
        // }

        // const fut = try ctx.io.concurrent(handleCon, .{ &serv, ctx });
        // errdefer fut.cancel(ctx.io);

        handleCon(&serv, ctx) catch |e| log.err("HyprIPC error: {}", .{e});
    }
}

pub const HyprEvent = union(enum) {
    const WS = Workspace.WS;
    const Out = Output.Wl;
    const Win = Window;
    const Trans = utils.Transaction;
    const Unimpl = union {};

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
    activespecial: struct { ?WS, Out },
    activespecialv2: struct { ?WS, Out },
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
            .workspace => |ws| try w.print("{}", .{ws + 1}),
            .workspacev2 => |ws| try w.print("{0},{0}", .{ws + 1}),
            .activespecial => |_s| {
                const _ws, const out = _s;
                if (_ws) |ws|
                    try w.print("{},{?s}", .{ ws + 1, out.name })
                else
                    try w.print(",{?s}", .{out.name});
            },
            .activespecialv2 => |_s| {
                const _ws, const out = _s;
                if (_ws) |ws|
                    try w.print("{0},{0},{1?s}", .{ ws + 1, out.name })
                else
                    try w.print(",,{?s}", .{out.name});
            },
            .createworkspace => |ws| try w.print("{}", .{ws + 1}),
            .createworkspacev2 => |ws| try w.print("{0},{0}", .{ws + 1}),
            .destroyworkspace => |ws| try w.print("{}", .{ws + 1}),
            .destroyworkspacev2 => |ws| try w.print("{0},{0}", .{ws + 1}),
            .focusedmon, .focusedmonv2 => |_s| {
                const out, const ws = _s;
                try w.print("{?s},{}", .{ out.name, ws + 1 });
            },

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
