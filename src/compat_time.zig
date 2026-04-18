const std = @import("std");
const fs = @import("compat_fs.zig");

pub const ns_per_us = std.time.ns_per_us;
pub const ns_per_ms = std.time.ns_per_ms;
pub const ns_per_s = std.time.ns_per_s;
pub const ms_per_s = std.time.ms_per_s;

pub fn nanoTimestamp() i128 {
    return @as(i128, std.Io.Timestamp.now(fs.io(), .real).nanoseconds);
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), ns_per_ms));
}

pub fn timestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), ns_per_s));
}
