const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;
const utils = @import("../utils.zig");

const Manager = @This();
const InputDevice = @import("device.zig");
const LibinputDevice = @import("libinput_device.zig");

const log = std.log.scoped(.input_manager);

manager: *rwm.InputManagerV1,
libinput: *rwm.LibinputConfigV1,

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
