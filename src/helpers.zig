const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Tiler = @import("tiler.zig");
const Window = @import("window.zig");
const Workspace = @import("workspace.zig");
const Output = @import("output.zig");
const Config = @import("config.zig");

pub fn spawnChild(ctx: *Context, command: []const u8) !void {
    var buf: [0x80000]u8 = @splat(0); // look if your env is more than 80 KiB I cannot help you
    var fb: std.heap.FixedBufferAllocator = .init(&buf);
    const alloc = fb.allocator();
    const env = try std.process.createEnvironFromMap(alloc, &ctx.child_env, .{});
    const pid = try std.posix.fork();

    var args = [_:null]?[*:0]const u8{ "sh", "-c", undefined };
    args[args.len - 1] = try alloc.dupeZ(u8, command);

    if (pid == 0) {
        const devNull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch posix.exit(1);
        posix.dup2(devNull, posix.STDERR_FILENO) catch posix.exit(1);
        posix.dup2(devNull, posix.STDOUT_FILENO) catch posix.exit(1);
        const sig_dfl = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &sig_dfl, null);
        posix.execveZ("/bin/sh", &args, env) catch posix.exit(1);
    }
}

pub fn disownChild(ctx: *Context, command: []const u8) !void {
    const pid = try posix.fork();
    if (pid == 0) {
        spawnChild(ctx, command) catch posix.exit(1);
        posix.exit(0);
    }
    const out = posix.waitpid(pid, 0);
    if (out.status != 0) return error.ChildFailed;
}

pub fn startup(ctx: *Context) void {
    const log = std.log.scoped(.startup);

    const list = ctx.config.getList("startup") catch |e| {
        log.err("failed to parse startup: {}", .{e});
        return;
    };

    for (list) |entry| {
        spawnChild(ctx, entry.args[0]) catch |e| {
            log.err("failed to start {any} : {}", .{ entry.args, e });
        };
    }
}
