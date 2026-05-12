const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");

pub const HelpConfig = struct {
    auto_switch: registry.AutoSwitchConfig,
};

pub fn loadHelpConfig(allocator: std.mem.Allocator, codex_home: []const u8) HelpConfig {
    var reg = registry.loadRegistry(allocator, codex_home) catch {
        return .{
            .auto_switch = registry.defaultAutoSwitchConfig(),
        };
    };
    defer reg.deinit(allocator);
    return .{
        .auto_switch = reg.auto_switch,
    };
}

pub fn handleTopLevelHelp(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const help_cfg = loadHelpConfig(allocator, codex_home);
    try cli.help.printHelp(&help_cfg.auto_switch);
}
