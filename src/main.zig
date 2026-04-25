const std = @import("std");
const codex_auth = @import("root.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    return codex_auth.workflows.main(init);
}
