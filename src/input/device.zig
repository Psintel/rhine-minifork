const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Manager = @import("management.zig");

const log = std.log.scoped(.InputDevice);

name: ?[]const u8 = null,
type: ?rwm.InputDeviceV1.Type = null,

pub fn listener(dev: *rwm.InputDeviceV1, event: rwm.InputDeviceV1.Event, man: *Manager) void {
    const data = man.devices.getPtr(dev).?;

    switch(event) {
        .name => |n| {
            data.name = std.mem.sliceTo(n.name, 0);
            log.info("device {} has name {s}", .{dev.getId(), data.name.?});
        },
        .type => |t| {
            data.type = t.type;
            log.info("device {} has type {s}", .{dev.getId(), @tagName(t.type)});
        },
        .removed => {
            std.debug.assert(man.devices.swapRemove(dev));
            dev.destroy();
        }
    }
}
