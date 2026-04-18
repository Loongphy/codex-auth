const std = @import("std");
const fs = @import("compat_fs.zig");
const auto = @import("auto.zig");
const registry = @import("registry.zig");

fn resolveDaemonCodexHome(allocator: std.mem.Allocator, init: std.process.Init.Minimal) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var codex_home_override: ?[]u8 = null;
    defer if (codex_home_override) |path| allocator.free(path);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--service-version")) {
            if (i + 1 >= args.len) return error.InvalidCliUsage;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-home")) {
            if (i + 1 >= args.len) return error.InvalidCliUsage;
            if (codex_home_override != null) return error.InvalidCliUsage;
            codex_home_override = try allocator.dupe(u8, args[i + 1]);
            i += 1;
            continue;
        }
        return error.InvalidCliUsage;
    }

    if (codex_home_override) |path| {
        return try registry.resolveCodexHomeFromEnv(allocator, path, null, null);
    }
    return try registry.resolveCodexHome(allocator);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const codex_home = try resolveDaemonCodexHome(allocator, init);
    defer allocator.free(codex_home);

    try auto.runDaemon(allocator, codex_home);
}
