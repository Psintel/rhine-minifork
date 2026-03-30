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
    abs: Workspace.WS,
    rel: WsDir,

    pub fn resolve(self: @This(), ctx: *Context, seat: *rwm.SeatV1) !Workspace.WS {
        switch (self) {
            .abs => |ws| return ws,
            .rel => |dr| {
                const current = Workspace.bySeat(ctx, seat) orelse return error.NoCurrentWorkspace;
                return switch (dr) {
                    .Previous => Workspace.getPrevious(ctx, current),
                    .Next => Workspace.getNext(ctx, current),
                };
            },
        }
    }
};

pub const Command = union(enum) {
    killFocus: void,
    launch: []const u8,
    toggleFullscreen: void,
    toggleFloating: void,
    toggleWorkspace: void,
    toggleSpecial: Workspace.WS,
    focusWorkspace: WsSpec,
    sendToWorkspace: WsSpec,
    moveToWorkspace: WsSpec,
    moveFocus: Tiler.Dir,
    moveWindow: Tiler.Dir,
    layoutCommand: struct { Layouts.LayoutType, Tiler.Command },
    exit: void,

    pub fn fromArg(args: *Config.Entry.Iterator) !@This() {
        const tag = meta.stringToEnum(
            meta.Tag(Command),
            args.next() orelse return error.NoCommand,
        ) orelse return error.InvalidTag;

        switch (tag) {
            inline .killFocus, .toggleFullscreen, .toggleFloating, .toggleWorkspace, .exit => |t| return @unionInit(@This(), @tagName(t), {}),
            .launch => return .{
                .launch = args.next() orelse return error.NoLaunchArg,
            },
            inline .moveFocus, .moveWindow => |t| return @unionInit(
                @This(),
                @tagName(t),
                meta.stringToEnum(
                    Tiler.Dir,
                    args.next() orelse return error.NoMoveArg,
                ) orelse return error.InvalidDirection,
            ),
            .toggleSpecial => {
                const ws = try std.fmt.parseInt(Workspace.WS, args.next() orelse return error.NoWsArg, 0);
                if (ws >= 0) return error.PositiveSpecialWorkspace;

                return .{ .toggleSpecial = ws };
            },
            inline .sendToWorkspace, .focusWorkspace, .moveToWorkspace => |t| {
                const arg = args.next() orelse return error.NoWsArg;
                const ws: WsSpec = if (std.fmt.parseInt(Workspace.WS, arg, 0)) |w|
                    .{ .abs = w }
                else |_|
                    .{ .rel = meta.stringToEnum(WsDir, arg) orelse return error.ParseError };

                return @unionInit(@This(), @tagName(t), ws);
            },
            .layoutCommand => {
                return .{ .layoutCommand = try Layouts.parseCommand(args) };
            },
        }
    }

    pub fn dispatch(cmd: @This(), ctx: *Context, seat: *rwm.SeatV1) !void {
        const seat_data = ctx.seats.getPtr(seat) orelse return error.NoSeat;
        log.info("dispatching command {} on seat {}", .{ cmd, seat.getId() });
        switch (cmd) {
            .killFocus => {
                if (seat_data.focus) |w| {
                    try ctx.should_close.append(ctx.gpa, w);
                    log.info("marked window {} for closure", .{w.getId()});
                    ctx.dirty = true;
                }
            },
            .launch => |command| {
                try helpers.disownChild(ctx, command);
            },
            .toggleFullscreen => {
                const focus = seat_data.focus orelse return;
                const win_data = ctx.wins.getPtr(focus) orelse return;
                win_data.fullscreen.toggle();
                ctx.dirty = true;
            },
            .toggleFloating => {
                const focus = seat_data.focus orelse return;
                const win_data = ctx.wins.getPtr(focus) orelse return;
                win_data.float = !win_data.float;
                log.info("toggled floating state of {}", .{focus.getId()});
                ctx.dirty = true;
            },
            .toggleWorkspace => {
                log.info("toggle keybinds", .{});
                const out = Output.bySeat(ctx, seat) orelse return;
                const out_data = ctx.outs.get(out) orelse return;
                const old = out_data.last_workspace orelse return;
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .focusWorkspace = .{ .abs = old } });
            },
            .toggleSpecial => |ws| {
                const out = Output.bySeat(ctx, seat) orelse return;
                const out_data = ctx.outs.getPtr(out).?;

                var target_ws: Workspace.WS = undefined;

                if (out_data.overlay == ws) {
                    out_data.overlay = null;
                    target_ws = out_data.workspace;
                } else {
                    out_data.overlay = ws;
                    target_ws = ws;
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

                log.info("sending workspace {}", .{ws});

                const s = ctx.workspaces.getPtr(source).?;
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
            .exit => {
                ctx.wm.exitSession();
            },
        }
    }
};
