const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const helpers = @import("helpers.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Seat = @import("seat.zig");
const Workspace = @import("workspace.zig");
const Rules = @import("rules.zig");
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Layouts = @import("layouts.zig");
const Config = @import("config.zig");
const pointer_ops = @import("pointer_ops.zig");

const log = std.log.scoped(.Commands);

pub const QueueItem = struct {
    command: Command,
    seat: *rwm.SeatV1,
    link: std.DoublyLinkedList.Node = .{},
};

pub const Queue = struct {
    mutex: std.Thread.Mutex.Recursive = .init,
    list: std.DoublyLinkedList = .{},

    pub fn add(self: *@This(), alloc: mem.Allocator, seat: *rwm.SeatV1, cmd: Command) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const new = try alloc.create(QueueItem);
        new.* = .{
            .command = cmd,
            .seat = seat,
        };

        self.list.prepend(&new.link);
    }

    pub fn addNoFail(self: *@This(), alloc: mem.Allocator, seat: *rwm.SeatV1, cmd: Command) void {
        self.add(alloc, seat, cmd) catch |e| log.err("{}: failed to add command {} to queue", .{ e, cmd });
    }
};

const WsDir = enum { Previous, Next };

const WsSpec = union(enum) {
    Abs: Workspace.WS,
    Rel: WsDir,
    PrevActive: void,

    pub fn resolve(self: @This(), ctx: *Context, seat: *rwm.SeatV1) !Workspace.WS {
        switch (self) {
            .Abs => |ws| return ws,
            .Rel => |dr| {
                const current = Workspace.bySeat(ctx, seat) orelse return error.NoCurrentWorkspace;
                return switch (dr) {
                    .Previous => Workspace.getPrevious(ctx, current),
                    .Next => Workspace.getNext(ctx, current),
                };
            },
            .PrevActive => {
                const out = Output.bySeat(ctx, seat) orelse return error.NotFound;
                const out_data = ctx.outs.get(out) orelse return error.NotFound;
                return out_data.last_workspace orelse error.NotFound;
            },
        }
    }

    pub fn parse(args: *Config.Entry.Iterator) !@This() {
        const Tag = meta.Tag(@This());
        const arg = args.next() orelse return error.NoWsArg;
        return if (std.fmt.parseInt(Workspace.WS, arg, 0)) |w|
            .{ .Abs = w }
        else |_| if (meta.stringToEnum(WsDir, arg)) |rel|
            .{ .Rel = rel }
        else if (meta.stringToEnum(Tag, arg) == .PrevActive)
            .{ .PrevActive = {} }
        else
            error.ParseError;
    }
};

const WinSpec = union(enum) {
    Focus: void,

    pub fn parse(args: *Config.Entry.Iterator) !@This() {
        const arg = args.next() orelse return error.ParseError;
        const t = meta.stringToEnum(meta.Tag(@This()), arg) orelse return error.ParseError;

        switch (t) {
            .Focus => return .{ .Focus = {} },
        }
    }

    pub fn resolve(self: @This(), ctx: *Context, seat: *rwm.SeatV1) ?*rwm.WindowV1 {
        const seat_data = ctx.seats.get(seat) orelse return null;
        switch (self) {
            .Focus => return seat_data.focus,
        }
    }
};

const ToggleCmd = enum { enable, disable, toggle };

pub const Command = union(enum) {
    close: WinSpec,
    kill: WinSpec,
    murder: WinSpec,
    launch: []const u8,
    fullscreen: struct { ToggleCmd, WinSpec },
    floating: struct { ToggleCmd, WinSpec },
    overlay: struct { ToggleCmd, Workspace.WS },
    focusWorkspace: WsSpec,
    sendToWorkspace: WsSpec,
    moveToWorkspace: WsSpec,
    moveFocus: Tiler.Dir,
    moveWindow: Tiler.Dir,
    layoutCommand: struct { Layouts.LayoutType, Tiler.Command },
    pointerOp: pointer_ops.OpType,
    exit: void,

    pub fn fromArg(args: *Config.Entry.Iterator) !@This() {
        const tag = meta.stringToEnum(
            meta.Tag(Command),
            args.next() orelse return error.NoCommand,
        ) orelse return error.InvalidTag;

        switch (tag) {
            inline .exit => |t| return @unionInit(@This(), @tagName(t), {}),
            .launch => return .{
                .launch = args.rest(),
            },
            .overlay => {
                const toggle = try args.parseT(ToggleCmd);
                const ws = try std.fmt.parseInt(Workspace.WS, args.next() orelse return error.NoWsArg, 0);
                if (ws >= 0) return error.PositiveSpecialWorkspace;

                return .{ .overlay = .{ toggle, ws } };
            },
            .layoutCommand => {
                return .{ .layoutCommand = try Layouts.parseCommand(args) };
            },
            inline else => |t| {
                return @unionInit(@This(), @tagName(t), try args.parseT(@FieldType(Command, @tagName(t))));
            },
        }
    }

    pub fn dispatch(cmd: @This(), ctx: *Context, seat: *rwm.SeatV1) !void {
        const seat_data = ctx.seats.getPtr(seat) orelse return error.NoSeat;
        log.info("dispatching command {} on seat {}", .{ cmd, seat.getId() });
        switch (cmd) {
            .close => |win| {
                if (win.resolve(ctx, seat)) |w| {
                    try ctx.should_close.append(ctx.gpa, w);
                    log.info("marked window {} for closure", .{w.getId()});
                    ctx.dirty = true;
                }
            },
            .kill => |win| {
                if (win.resolve(ctx, seat)) |w| {
                    const win_data = ctx.wins.get(w) orelse return error.NotFound;
                    if (win_data.unreliable_pid) |pid| {
                        log.info("sent SIGTERM to {}", .{w.getId()});
                        try std.posix.kill(pid, std.posix.SIG.TERM);
                    } else {
                        log.err("can't kill {} does not have pid", .{w.getId()});
                    }
                }
            },
            .murder => |win| {
                if (win.resolve(ctx, seat)) |w| {
                    const win_data = ctx.wins.get(w) orelse return error.NotFound;
                    if (win_data.unreliable_pid) |pid| {
                        log.info("sent SIGTERM to {}", .{w.getId()});
                        try std.posix.kill(pid, std.posix.SIG.KILL);
                    } else {
                        log.err("can't kill {} does not have pid", .{w.getId()});
                    }
                }
            },
            .launch => |command| {
                try helpers.disownChild(ctx, command);
            },
            .fullscreen => |args| {
                const state, const target = args;
                const win = target.resolve(ctx, seat) orelse return;
                const win_data = ctx.wins.getPtr(win) orelse return;
                switch (state) {
                    .enable => win_data.fullscreen.on(),
                    .disable => win_data.fullscreen.off(),
                    .toggle => win_data.fullscreen.toggle(),
                }
                ctx.dirty = true;
            },
            .floating => |args| {
                const state, const target = args;
                const win = target.resolve(ctx, seat) orelse return;
                const win_data = ctx.wins.getPtr(win) orelse return;
                win_data.float = switch (state) {
                    .enable => true,
                    .disable => false,
                    .toggle => !win_data.float,
                };
                log.info("set floating state of {} to {}", .{ win.getId(), win_data.float });
                ctx.dirty = true;
            },
            .overlay => |args| {
                const state, const ws = args;
                const out = Output.bySeat(ctx, seat) orelse return;
                const out_data = ctx.outs.getPtr(out).?;

                var target_ws: Workspace.WS = undefined;

                ovrl: switch (state) {
                    .enable => {
                        out_data.overlay = ws;
                        target_ws = ws;
                    },
                    .disable => {
                        out_data.overlay = null;
                        target_ws = out_data.workspace;
                    },

                    .toggle => {
                        if (out_data.overlay == ws) continue :ovrl .disable;
                        continue :ovrl .enable;
                    },
                }

                log.info("toggled special workspace {}", .{ws});

                const ws_data = Workspace.get(ctx, target_ws) catch return;

                seat_data.focus = if (ws_data.windows.entries.len > 0) ws_data.windows.keys()[0] else null;
                seat_data.warp_to_window = seat_data.focus;
                ctx.dirty = true;
            },
            .focusWorkspace => |_ws| {
                const ws = try _ws.resolve(ctx, seat);
                const out = Output.bySeat(ctx, seat) orelse return;
                const out_data = ctx.outs.getPtr(out).?;

                const w = Workspace.get(ctx, ws) catch |e| {
                    log.err("failed to switch to workspace {} with error {}", .{ ws, e });
                    return;
                };

                log.info("switching to workspace {}", .{ws});

                if (Workspace.getOutput(ctx, ws) == null) {
                    out_data.setWorkspace(ctx, ws);
                }

                seat_data.focus = if (w.windows.entries.len > 0) w.windows.keys()[0] else null;
                seat_data.warp_to_window = seat_data.focus;
                ctx.dirty = true;
            },
            .sendToWorkspace => |_ws| {
                const ws = try _ws.resolve(ctx, seat);
                const focus = seat_data.focus orelse return;
                const source = Window.getWorkspace(ctx, focus) orelse return;

                if (source == ws) return;

                const w = Workspace.get(ctx, ws) catch |e| {
                    log.err("failed send to workspace {} with error {}", .{ ws, e });
                    return;
                };

                const s = ctx.workspaces.getPtr(source).?;

                log.info("sending workspace {}", .{ws});

                // floating case
                if (s.floating.swapRemove(focus)) {
                    w.floating.put(ctx.gpa, focus, {}) catch ctx.orphan(focus);
                    return;
                }

                // tiling case
                const tc: Tiler.TileContext = .{
                    .cursorPos = Output.relPos(ctx, seat_data.pointer_pos),
                    .focus = seat_data.focus,
                    .gpa = ctx.gpa,
                };

                s.rmWindow(tc, focus);
                w.addWindow(tc, focus) catch |e| {
                    log.err("error adding window {} to workspace {}: {}", .{ focus.getId(), ws, e });
                    ctx.orphan(focus);
                };

                ctx.dirty = true;
            },
            .moveFocus => |dir| {
                const win = seat_data.focus orelse return;
                const win_data = ctx.wins.getPtr(win) orelse return;
                const ws_id = Window.getWorkspace(ctx, win) orelse return error.OrphanedFocus;
                const ws = ctx.workspaces.getPtr(ws_id).?;

                if (ws.getWindow(.{
                    .focus = seat_data.focus,
                    .gpa = ctx.gpa,
                }, dir)) |w| {
                    win_data.fullscreen.off();
                    seat_data.focus = w;
                    seat_data.warp_to_window = w;
                    log.info("focus  window {}", .{w.getId()});
                    ctx.dirty = true;
                }
            },
            .moveWindow => |dir| {
                const win = seat_data.focus orelse return;
                const win_data = ctx.wins.getPtr(win) orelse return;
                const ws_id = Window.getWorkspace(ctx, win) orelse return error.OrphanedFocus;
                const ws = ctx.workspaces.getPtr(ws_id).?;

                if (win_data.float) {
                    const t = std.time.microTimestamp();
                    const out = Output.byWorkspace(ctx, ws_id) orelse return;
                    const out_data = ctx.outs.get(out) orelse return;
                    const out_area = out_data.getArea();
                    const pos = win_data.pos.get(ctx.anims, t);
                    const size = win_data.size;
                    const constr_area = utils.Rect2{
                        .pos = out_area.pos,
                        .dim = out_area.dim - size,
                    };
                    const dir_sign: utils.Vec2 = switch (dir) {
                        .Left => .{ -1, 0 },
                        .Right => .{ 1, 0 },
                        .Up => .{ 0, -1 },
                        .Down => .{ 0, 1 },
                    };

                    const dir_vec: utils.Vec2 = @as(utils.Vec2, @splat(25)) * dir_sign;
                    const new_pos = constr_area.constrain(pos + dir_vec);

                    win_data.pos = .{ .static = new_pos };
                } else {
                    ws.move(.{ .gpa = ctx.gpa, .focus = win }, dir);
                }

                seat_data.warp_to_window = win;
                ctx.dirty = true;
            },
            .moveToWorkspace => |ws| {
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .sendToWorkspace = ws });
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .focusWorkspace = ws });
            },
            .layoutCommand => |_laycmd| {
                const tag, const laycmd = _laycmd;
                const ws = Workspace.bySeat(ctx, seat) orelse return error.NoSeatFound;
                const ws_data = try Workspace.get(ctx, ws);
                if (tag != ws_data.tiler.tag) return;
                try ws_data.command(.{
                    .gpa = ctx.gpa,
                    .focus = seat_data.focus,
                }, laycmd);
                ctx.dirty = true;
            },
            .pointerOp => |op| {
                try pointer_ops.startOp(ctx, seat, op);
            },
            .exit => {
                ctx.wm.exitSession();
            },
        }
    }
};
