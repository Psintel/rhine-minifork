const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;
const utils = @import("../utils.zig");
const Config = @import("../config.zig");

const Manager = @This();
const InputDevice = @import("device.zig");
const LibinputDevice = @import("libinput_device.zig");

const log = std.log.scoped(.input_manager);

manager: *rwm.InputManagerV1,
libinput: *rwm.LibinputConfigV1,
dirty: bool = true,

gpa: mem.Allocator,
devices: utils.WLHashMap(rwm.InputDeviceV1, InputDevice) = .empty,
libinput_devs: utils.WLHashMap(rwm.LibinputDeviceV1, LibinputDevice) = .empty,

input_results: std.ArrayList(*rwm.LibinputResultV1) = .empty,

pub fn listener(iface: *rwm.InputManagerV1, event: rwm.InputManagerV1.Event, ctx: *Manager) void {
    switch (event) {
        .input_device => |d| {
            const dev = d.id;
            ctx.devices.put(ctx.gpa, dev, .{}) catch return;
            dev.setListener(*Manager, InputDevice.listener, ctx);
        },
        .finished => {
            iface.destroy();
        },
    }
}

pub fn applyConfig(self: *Manager, cfg: Config) !void {
    // keyboards
    const keyboard_cfg = try cfg.sub("keyboard");
    const Repeat = struct {
        rate: i32,
        delay: i32,
    };
    var repeat: Repeat = .{ .rate = 20, .delay = 20 };
    const repeat_cfg = try keyboard_cfg.sub("repeat");

    if (try repeat_cfg.getSole("rate")) |rt| {
        repeat.rate = try std.fmt.parseInt(i32, rt, 0);
    }
    if (try repeat_cfg.getSole("delay")) |dl| {
        repeat.delay = try std.fmt.parseInt(i32, dl, 0);
    }

    var dev_iter = self.devices.iterator();

    while (dev_iter.next()) |_dev| {
        const dev = _dev.key_ptr.*;
        const dev_data = _dev.value_ptr;

        switch (dev_data.type orelse continue) {
            .keyboard => {
                log.info("set keyboard repeat to {any}", .{repeat});
                dev.setRepeatInfo(repeat.rate, repeat.delay);
            },
            else => |t| {
                log.warn("not configuring device of type {}", .{t});
            },
        }
    }
}
