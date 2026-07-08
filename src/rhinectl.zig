const std = @import("std");
const Io = std.Io;
const process = std.process;
const mem = std.mem;
const debug = std.debug;

fn oneOf(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |h| {
        if (mem.eql(u8, needle, h)) return true;
    }
    return false;
}

pub fn main(init: process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var b: [0x200]u8 = undefined;

    var arg_iter = init.minimal.args.iterate();

    var json: bool = false;
    var help: bool = false;

    var fst: ?[]const u8 = undefined;

    const stdout = Io.File.stdout();

    debug.assert(arg_iter.skip());

    while (arg_iter.next()) |arg| {
        if (oneOf(arg, &.{ "-h", "--help" })) {
            help = true;
        } else if (oneOf(arg, &.{ "-j", "--json" })) {
            json = true;
        } else {
            fst = arg;
            break;
        }
    } else {
        help = true;
    }

    if (help) {
        try stdout.writeStreamingAll(io,
            \\ ============ rhinectl ============
            \\ rhinectl : a hyprctl stub for rhine
            \\
            \\ usage: rhinectl [flags] <command>
            \\
            \\ <command> is a hyprctl command the below:
            \\
            \\ use: rhinectl rhine <cmd>
            \\
            \\ where <cmd> is a rhine command. same syntax as a keybind
            \\
        );
        return;
    }

    if (fst == null) process.fatal("no argument, use riverctl -h to get help", .{});

    const sig = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.InstanceNotFound;
    const runtime = env.get("XDG_RUNTIME_DIR") orelse return error.XDGNotFound;
    const sockpath = try std.fs.path.join(gpa, &.{ runtime, "hypr", sig, ".socket.sock" });

    const sock: Io.net.UnixAddress = try .init(sockpath);
    const connection = try sock.connect(io);
    defer connection.close(io);

    var writer_obj = connection.writer(io, &b);
    const writer = &writer_obj.interface;

    if (json) try writer.writeByte('j');
    try writer.writeByte('/');
    try writer.writeAll(fst.?);
    while (arg_iter.next()) |arg| {
        try writer.print(" {s}", .{arg});
    }
    try writer.flush();

    var reader = connection.reader(io, &.{});
    var stdout_writer = stdout.writerStreaming(io, &b);
    _ = try reader.interface.streamRemaining(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
