const std = @import("std");
const wayland = @import("wayland");
const tributary = @import("tributary");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

const wl = wayland.client.wl;
const rwm = wayland.client.river;
const Io = std.Io;

const utils = tributary.utils;
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Output = @import("output.zig");
const Config = tributary.Config;

fn fork() !posix.pid_t {
    const pid = posix.system.fork();
    switch (posix.errno(pid)) {
        .SUCCESS => return pid,
        else => return error.NoFork,
    }
}

const exit = std.process.exit;

const fatal = std.process.fatal;

pub fn _spawnChild(ctx: *Context, command: []const u8, disown: bool) !void {
    var buf: [0x80000]u8 = @splat(0); // look if your env is more than 80 KiB I cannot help you
    var fb: std.heap.FixedBufferAllocator = .init(&buf);
    const alloc = fb.allocator();
    const env = try ctx.child_env.createPosixBlock(alloc, .{});
    const pid = try fork();

    const args = [_:null]?[*:0]const u8{ "sh", "-c", try alloc.dupeZ(u8, command) };

    if (pid == 0) {
        if (disown) {
            if (posix.system.setsid() < 0) exit(1);
        } else {
            _ = posix.prctl(.SET_PDEATHSIG, .{@intFromEnum(posix.SIG.TERM)}) catch exit(1);
        }
        const devNull = posix.system.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devNull < 0) exit(1);
        if (posix.system.dup2(devNull, posix.STDERR_FILENO) < 0) exit(1);
        if (posix.system.dup2(devNull, posix.STDOUT_FILENO) < 0) exit(1);
        _ = posix.system.execve("/bin/sh", &args, env.slice);
        exit(1);
    }
}

pub fn spawnChild(ctx: *Context, command: []const u8, comptime disown: bool) !void {
    var buf: [0x80000]u8 = @splat(0); // look if your env is more than 80 KiB I cannot help you
    var fb: std.heap.FixedBufferAllocator = .init(&buf);
    const alloc = fb.allocator();
    const env = try ctx.child_env.createPosixBlock(alloc, .{});
    const args = [_:null]?[*:0]const u8{ "sh", "-c", try alloc.dupeZ(u8, command) };

    const pid = try fork();
    if (pid == 0) {
        posix.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);
        if (disown) {
            if (posix.system.setsid() < 0) exit(1);
        } else {
            _ = posix.prctl(.SET_PDEATHSIG, .{@intFromEnum(posix.SIG.TERM)}) catch exit(1);
        }
        const devNull = posix.system.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (devNull < 0) exit(1);
        if (posix.system.dup2(devNull, posix.STDERR_FILENO) < 0) exit(1);
        if (posix.system.dup2(devNull, posix.STDOUT_FILENO) < 0) exit(1);
        _ = posix.system.execve("/bin/sh", &args, env.slice);
        exit(1);
    }
}

pub fn disownChild(ctx: *Context, command: []const u8) !void {
    const pid = try fork();
    if (pid == 0) {
        spawnChild(ctx, command, true) catch exit(1);
        exit(0);
    }
    var status: c_int = undefined;
    _ = posix.system.waitpid(pid, &status, 0);
    if (posix.system.W.EXITSTATUS(@bitCast(status)) != 0) return error.SpawnError;
}

pub fn startup(ctx: *Context) void {
    const log = std.log.scoped(.startup);

    const list = ctx.config.getList("startup") catch |e| {
        log.err("failed to parse startup: {}", .{e});
        return;
    };

    for (list) |entry| {
        spawnChild(ctx, entry.args, false) catch |e| {
            log.err("failed to start {any} : {}", .{ entry.args, e });
        };
    }
}
