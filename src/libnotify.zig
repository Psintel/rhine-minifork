const opts = @import("options");
const std = @import("std");
const log = std.log.scoped(.notification);

extern "notify.h" fn notify_init([*c]const u8) c_int;
extern "notify.h" fn notify_uninit() void;
pub const GError = extern struct {
    domain: c_int,
    code: c_int,
    message: [*c]u8,

    extern fn g_clear_error(*?*@This()) void;
    pub const clear = g_clear_error;
};
pub const Notification = opaque {
    pub const Urgency = enum(c_int) {
        Low,
        Normal,
        Critical,
    };

    extern "notify.h" fn notify_notification_new(
        summary: [*c]const u8,
        body: [*c]const u8,
        icon: [*c]const u8,
    ) *Notification;
    extern "notify.h" fn notify_notification_show(
        *Notification,
        err: ?*?*GError,
    ) c_int;

    extern "notify.h" fn notify_notification_set_timeout(
        *Notification,
        milis: c_int,
    ) void;

    extern "notify.h" fn notify_notification_set_urgency(
        *Notification,
        urgency: Urgency,
    ) void;

    extern fn g_object_unref(*Notification) void;

    pub const new = notify_notification_new;
    pub const deinit = g_object_unref;
    pub const show = notify_notification_show;
    pub const setTimeout = notify_notification_set_timeout;
    pub const setUrgency = notify_notification_set_urgency;
};


pub fn init() !void {
    if (opts.libnotify) if (notify_init("rhine") == 0) return error.NotifyInit;
}

pub fn deinit() void {
    if (opts.libnotify) notify_uninit();
}

const NotifyOptions = struct {
    summary: [:0]const u8 = "",
    body: [:0]const u8 = "",
    duration: u31 = 3000,
    urgency: Notification.Urgency = .Normal,
};

pub fn send(notification: NotifyOptions) !void {
    if (!opts.libnotify) return;

    const not = Notification.new(notification.summary, notification.body, null);
    defer not.deinit();
    not.setTimeout(notification.duration);
    not.setUrgency(notification.urgency);

    var err: ?*GError = null;
    if (not.show(&err) == 0) {
        if (err) |e| {
            log.err("error showing notification: {s}", .{e.message});
            GError.clear(&err);
        }
        return error.NotificationError;
    }
}
