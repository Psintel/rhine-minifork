const std = @import("std");
const wayland = @import("wayland");
const mem = std.mem;

const wl = wayland.client.wl;
const rwm = wayland.client.river;

const Manager = @import("management.zig");
const LibinputDevice = @import("libinput_device.zig");

const log = std.log.scoped(.Libinput);

results: std.ArrayList(*rwm.LibinputResultV1) = .empty,

pub fn listener(libinput: *rwm.LibinputConfigV1, event: rwm.LibinputConfigV1.Event, man: *Manager) void {
    _ = libinput;

    switch (event) {
        .libinput_device => |d| {
            const dev = d.id;

            man.libinput_devs.put(man.gpa, dev, .{}) catch
                std.debug.panic("allocation failure when registering libinput device", .{});
            dev.setListener(*Manager, LibinputDevice.listener, man);

        },
        .finished => {
            for (man.libinput_devs.keys()) |dev| {
                dev.destroy();
            }
            man.libinput_devs.clearAndFree(man.gpa);
        },
    }
}
