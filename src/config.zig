const std = @import("std");

const separator: u8 = ':';
const terminator: u8 = ',';

const Config = @This();

pub const Value = union {
    config: *Config,
};

values: std.StringHashMapUnmanaged()
