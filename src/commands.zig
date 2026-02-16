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

pub const Command = union(enum) {
    killFocus: void,
    launch: []const u8,
    tiler: Tiler.Command,
    toggleFullscreen: void,
    toggleWorkspace: void,
    toggleSpecial: Workspace.WS,
    focusWorkspace: Workspace.WS,
    sendFocusToWorkspace: Workspace.WS,
    moveToWorkspace: Workspace.WS,
    moveFocus: Tiler.Dir,
    moveWindow: Tiler.Dir,
    layoutCommand: Tiler.Command,

    pub fn fromArg(args: []const []const u8) !@This() {
        const tag = meta.stringToEnum(meta.Tag(Command), args[0]) orelse return error.InvalidTag;

        switch (tag) {
            inline .killFocus, .toggleFullscreen, .toggleWorkspace => |t| return @unionInit(@This(), @tagName(t), {}),
            .launch => return .{ .launch = args[1] },
            .moveFocus => return .{
                .moveFocus = meta.stringToEnum(Tiler.Dir, args[1]) orelse return error.InvalidDirection,
            },
            .moveWindow => return .{
                .moveWindow = meta.stringToEnum(Tiler.Dir, args[1]) orelse return error.InvalidDirection,
            },
            .toggleSpecial => {
                const ws = try std.fmt.parseInt(Workspace.WS, args[1], 0);
                if (ws >= 0) return error.PositiveSpecialWorkspace;

                return .{ .toggleSpecial = ws };
            },
            inline .sendFocusToWorkspace, .focusWorkspace, .moveToWorkspace => |t| {
                const ws = try std.fmt.parseInt(Workspace.WS, args[1], 0);

                return @unionInit(@This(), @tagName(t), ws);
            },
            .layoutCommand => {
                return .{ .layoutCommand = try Layouts.parseCommand(args[1..]) };
            },
            else => {
                return error.NotImplemented;
            },
        }
    }

    pub fn dispatch(cmd: @This(), ctx: *Context, seat: *rwm.SeatV1) !void {
        const seat_data = ctx.seats.getPtr(seat) orelse return error.NoSeat;
        switch (cmd) {
            .killFocus => {
                if (seat_data.focus) |w| {
                    try ctx.should_close.append(ctx.gpa, w);
                    log.info("marked window {} for closure", .{w.getId()});
                    ctx.dirty = true;
                }
            },
            .launch => |command| {
                try helpers.spawnChild(ctx, &.{command}, true);
            },
            .toggleFullscreen => {
                const focus = seat_data.focus orelse return;
                const win_data = ctx.wins.getPtr(focus) orelse return;
                win_data.fullscreen.toggle();
                ctx.dirty = true;
            },
            .toggleWorkspace => {
                log.info("toggle keybinds", .{});
                const out = Output.bySeat(ctx, seat) orelse return;
                const out_data = ctx.outs.get(out) orelse return;
                const old = out_data.last_workspace orelse return;
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .focusWorkspace = old });
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
            .focusWorkspace => |ws| {
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
            .sendFocusToWorkspace => |ws| {
                const focus = seat_data.focus orelse return;
                const source = Window.getWorkspace(ctx, focus) orelse return;

                if (source == ws) return;

                const w = Workspace.get(ctx, ws) catch |e| {
                    log.err("failed send to workspace {} with error {}", .{ ws, e });
                    return;
                };

                log.info("sending workspace {}", .{ws});

                const s = ctx.workspaces.getPtr(source).?;
                var tc: Tiler.TileContext = .{
                    .cursorPos = seat_data.pointer_pos,
                    .focus = seat_data.focus,
                    .gpa = ctx.gpa,
                };

                s.rmWindow(&tc, focus);
                w.addWindow(&tc, focus) catch |e| {
                    log.err("error adding window {} to workspace {}: {}", .{ focus.getId(), ws, e });
                    ctx.orphan(focus);
                };

                ctx.dirty = true;
            },
            .moveFocus => |dir| {
                const win = seat_data.focus orelse return;
                const ws_id = Window.getWorkspace(ctx, win) orelse return error.OrphanedFocus;
                const ws = ctx.workspaces.getPtr(ws_id).?;
                var tc: Tiler.TileContext = .{
                    .focus = seat_data.focus,
                    .gpa = ctx.gpa,
                };
                if (ws.getWindow(&tc, dir)) |w| {
                    seat_data.focus = w;
                    seat_data.warp_to_window = w;
                    log.info("focus  window {}", .{w.getId()});
                    ctx.dirty = true;
                }
            },
            .moveWindow => |dir| {
                const win = seat_data.focus orelse return;
                const ws_id = Window.getWorkspace(ctx, win) orelse return error.OrphanedFocus;
                const ws = ctx.workspaces.getPtr(ws_id).?;
                var tc: Tiler.TileContext = .{
                    .focus = win,
                    .gpa = ctx.gpa,
                };
                ws.move(&tc, dir);
                seat_data.warp_to_window = win;
                ctx.dirty = true;
            },
            .moveToWorkspace => |ws| {
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .sendFocusToWorkspace = ws });
                try ctx.commands_queue.add(ctx.gpa, seat, .{ .focusWorkspace = ws });
            },
            .layoutCommand => |laycmd| {
                const ws = Workspace.bySeat(ctx, seat) orelse return error.NoSeatFound;
                const ws_data = try Workspace.get(ctx, ws);
                var tc: Tiler.TileContext = .{
                    .focus = seat_data.focus,
                    .gpa = ctx.gpa,
                };
                try ws_data.command(&tc, laycmd);
                ctx.dirty = true;
            },
            else => {
                log.err("command {} not implemented yet", .{cmd});
            },
        }
    }
};
