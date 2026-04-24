const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;
const meta = std.meta;
const mem = std.mem;
const Io = std.Io;

const SigEvent = @This();
file: Io.File,

const Flags = struct {
    NONBLOCK: bool = false,
    CLOEXEC: bool = false,
    pub fn toInt(self: @This()) u32 {
        var out: u32 = 0;
        inline for (comptime meta.fieldNames(@This())) |f| {
            if (@field(self, f))
                out |= @field(linux.SFD, f);
        }

        return out;
    }
};

const a = type{ i32, i32 };

const Signals = sigs: {
    const Type = std.builtin.Type;
    const _decls = meta.fields(posix.SIG);
    var darray: [_decls.len]Type.EnumField = undefined;
    @memcpy(&darray, _decls);
    var decls: []Type.EnumField = &darray;
    var i: usize = 0;
    while (i < decls.len) {
        if (mem.eql(u8, "BLOCK", decls[i].name) or
            mem.eql(u8, "UNBLOCK", decls[i].name) or
            mem.eql(u8, "SETMASK", decls[i].name))
        {
            decls[i] = decls[decls.len - 1];
            decls.len -= 1;
        } else {
            i += 1;
        }
    }

    var names: [decls.len][]const u8 = undefined;

    for (decls, &names) |decl, *n| {
        n.* = decl.name;
    }

    break :sigs @Struct(.auto, null, &names, &@splat(bool), &@splat(.{ .default_value_ptr = &false }));
};

pub fn toSet(signals: Signals) posix.sigset_t {
    var sigs = posix.sigemptyset();
    inline for (comptime meta.fieldNames(Signals)) |f| {
        if (@field(signals, f)) {
            posix.sigaddset(&sigs, @field(posix.SIG, f));
            std.log.warn("enabling {s} : {}", .{ f, @field(posix.SIG, f) });
        }
    }
    return sigs;
}


pub fn init(signals: Signals, flags: Flags) !@This() {
    var sigs = toSet(signals);

    posix.sigprocmask(posix.SIG.BLOCK, &sigs, null);

    return .{ .file = .{
        .flags = .{ .nonblocking = flags.NONBLOCK },
        .handle = try posix.signalfd(-1, &sigs, flags.toInt()),
    } };
}

pub fn readSignal(self: @This(), io: Io) !?linux.signalfd_siginfo {
    var buff: [@sizeOf(linux.signalfd_siginfo)]u8 = undefined;
    var reader = self.file.reader(io, &buff);
    return reader.interface.takeStruct(linux.signalfd_siginfo, .little) catch |e| switch (e) {
        error.ReadFailed => null,
        else => e,
    };
}

pub fn deinit(self: @This(), io: Io) void {
    self.file.close(io);
}

test "basic" {
    const testing = std.testing;
    const sighandler: SigEvent = try .init(.{ .CHLD = true }, .{ .NONBLOCK = true });
    defer sighandler.deinit();
    var chld = std.process.Child.init(&.{ "notify-send", "hello" }, testing.allocator);
    try chld.spawn();
    std.log.warn("{}", .{chld.id});
    const sig = try sighandler.readSignal();
    _ = try chld.wait();
    std.log.warn("{?}", .{sig});
}
