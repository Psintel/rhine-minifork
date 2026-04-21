const std = @import("std");
const builtin = @import("builtin");
const native = builtin.target.cpu.arch.endian();
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;

const Io = std.Io;

inot_file: Io.File,

pub const WatchDescriptor = packed struct {
    id: i32,
};

const RawEvent = packed struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,

    pub fn asEvent(self: @This()) Event {
        std.debug.assert(self.len == 0);
        return .{
            .wd = .{ .id = self.wd },
            .mask = @bitCast(self.mask),
            .cookie = self.cookie,
            .name = &.{},
        };
    }

    pub fn asNamedEvent(self: @This(), name: []u8) Event {
        std.debug.assert(self.len == name.len);
        return .{
            .wd = .{ .id = self.wd },
            .mask = @bitCast(self.mask),
            .cookie = self.cookie,
            .name = name,
        };
    }
};

pub const Event = struct {
    wd: WatchDescriptor,
    mask: Mask,
    cookie: u32,
    name: []u8,
};

pub const Mask = packed struct(u32) {
    ACCESS: bool = false,
    MODIFY: bool = false,
    ATTRIB: bool = false,
    CLOSE_WRITE: bool = false,
    CLOSE_NOWRITE: bool = false,
    OPEN: bool = false,
    MOVED_FROM: bool = false,
    MOVED_TO: bool = false,
    CREATE: bool = false,
    DELETE: bool = false,
    DELETE_SELF: bool = false,
    MOVE_SELF: bool = false,
    _: u20 = 0,

    pub const ALL: @This() = @bitCast(@as(u32, 0xfff));
};

const Flags = struct {
    nonblock: bool = false,
    close_on_exec: bool = false,

    pub fn toInt(self: @This()) u32 {
        var out: u32 = 0;
        if (self.nonblock) out |= linux.IN.NONBLOCK;
        if (self.close_on_exec) out |= linux.IN.CLOEXEC;

        return out;
    }
};

pub fn init(flags: Flags) !@This() {
    const fd = posix.system.inotify_init1(flags.toInt());
    if (fd < 0) return error.InitFailed;
    return .{ .inot_file = .{
        .handle = fd,
        .flags = .{ .nonblocking = flags.nonblock },
    } };
}

pub fn deinit(self: @This(), io: Io) void {
    self.inot_file.close(io);
}

pub fn watch(self: @This(), path: []const u8, mask: Mask) !WatchDescriptor {
    const id = posix.system.inotify_add_watch(self.inot_file.handle, &try posix.toPosixPath(path), @bitCast(mask));
    if (id < 0) return error.Failed;
    return .{
        .id = id,
    };
}

pub fn unwatch(self: @This(), watcher: WatchDescriptor) void {
    posix.inotify_rm_watch(self.inot_file.handle, watcher.id);
}

pub fn nextEvent(self: @This(), io: Io) !?Event {
    var buf: [@sizeOf(RawEvent)]u8 = undefined;
    var reader = self.inot_file.reader(io, &buf);

    const raw = reader.interface.takeStruct(RawEvent, native) catch |e| switch (e) {
        error.ReadFailed => return null,
        else => return e,
    };

    return raw.asEvent();
}

pub fn namedEvent(self: @This(), gpa: mem.Allocator) !?Event {
    var buf: [@sizeOf(RawEvent)]u8 = undefined;
    var reader = self.inot_file.reader(&buf);

    const raw = reader.interface.takeStruct(RawEvent, native) catch |e| switch (e) {
        error.ReadFailed => return null,
        else => return e,
    };

    return raw.asNamedEvent(try reader.interface.readAlloc(gpa, raw.len));
}
