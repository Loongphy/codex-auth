const std = @import("std");
const auto = @import("auto.zig");
const registry = @import("registry.zig");

const DaemonTarget = union(enum) {
    codex_home: []u8,
    manager: void,

    fn deinit(self: *DaemonTarget, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .codex_home => |path| allocator.free(path),
            .manager => {},
        }
    }
};

fn resolveDaemonTarget(allocator: std.mem.Allocator, init: std.process.Init.Minimal) !DaemonTarget {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var codex_home_override: ?[]u8 = null;
    defer if (codex_home_override) |path| allocator.free(path);
    var manager = false;

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
        if (std.mem.eql(u8, arg, "--manager")) {
            if (manager or codex_home_override != null) return error.InvalidCliUsage;
            manager = true;
            continue;
        }
        return error.InvalidCliUsage;
    }

    if (manager) return .{ .manager = {} };
    if (codex_home_override) |path| {
        return .{ .codex_home = try registry.resolveCodexHomeFromEnv(allocator, path, null, null) };
    }
    return .{ .codex_home = try registry.resolveCodexHome(allocator) };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var target = try resolveDaemonTarget(allocator, init);
    defer target.deinit(allocator);

    switch (target) {
        .codex_home => |codex_home| try auto.runDaemon(allocator, codex_home),
        .manager => try auto.runManagerDaemon(allocator),
    }
}
