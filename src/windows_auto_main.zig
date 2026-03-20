const std = @import("std");
const auto = @import("auto.zig");
const registry = @import("registry.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const codex_home = try registry.resolveCodexHome(allocator);
    defer allocator.free(codex_home);

    try auto.runDaemon(allocator, codex_home);
}
