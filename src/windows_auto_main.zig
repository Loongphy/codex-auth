const std = @import("std");
const auto = @import("auto.zig");
const registry = @import("registry.zig");

fn resolveDaemonCodexHome(allocator: std.mem.Allocator) ![]u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const codex_home = try resolveDaemonCodexHome(allocator);
    defer allocator.free(codex_home);

    try auto.runDaemon(allocator, codex_home);
}
