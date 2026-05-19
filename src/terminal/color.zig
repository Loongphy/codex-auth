const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn fileColorEnabled(file: std.Io.File) bool {
    return file.isTty(app_runtime.io()) catch false;
}
