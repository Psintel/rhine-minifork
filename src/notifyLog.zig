const std = @import("std");
const fmt = std.fmt;
const log = std.log;

const tributary = @import("tributary");
const Notify = tributary.Nobloatify;

pub fn logFn(
    comptime level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    log.defaultLog(level, scope, format, args);
    if (level != .err) return;
    Notify.init() catch return;
    var buffer: [0x200]u8 = undefined;
    const desc = fmt.bufPrintSentinel(&buffer, format, args, 0) catch return;
    Notify.send(.{
        .summary = "Rhine Error",
        .description = desc,
        .urgency = .critical,
    }) catch return;
}
