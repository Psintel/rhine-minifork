const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Manager = @import("management.zig");
const Libinput = @import("libinput.zig");

const log = std.log.scoped(.LibinputDevice);

const Capabilities = struct {
    natural_scroll: bool = false,
};

device: ?*rwm.InputDeviceV1 = null,
capabilities: Capabilities = .{},

pub fn listener(dev: *rwm.LibinputDeviceV1, event: rwm.LibinputDeviceV1.Event, man: *Manager) void {
    const data = man.libinput_devs.getPtr(dev).?;

    switch (event) {
        .input_device => |d| {
            const idev = d.device.?;
            data.device = idev;

            log.info("input dev {} is associated to libinput {}", .{ dev.getId(), idev.getId() });
        },
        .natural_scroll_support => |nat_scroll| {
            if (nat_scroll.supported != 0) data.capabilities.natural_scroll = true;
        },
        else => {
            log.warn("cannot handle event {s}", .{@tagName(event)});
        },
    }
}
