const std = @import("std");
const codex_auth = @import("root.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    return codex_auth.workflows.main(init);
}
