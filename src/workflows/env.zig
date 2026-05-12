const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn nowMilliseconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
}

pub fn nowSeconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
}
