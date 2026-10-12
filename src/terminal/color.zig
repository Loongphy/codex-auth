const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub fn fileColorEnabled(file: std.Io.File) bool {
    const mode = std.Io.Terminal.Mode.detect(
        app_runtime.io(),
        file,
        app_runtime.envHasValue("NO_COLOR"),
        false,
    ) catch return false;
    return switch (mode) {
        .escape_codes => true,
        else => false,
    };
}
