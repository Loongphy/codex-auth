const std = @import("std");
const registry = @import("../registry/root.zig");

pub const SwitchSelectionDisplay = struct {
    reg: *registry.Registry,
    usage_overrides: ?[]const ?[]const u8,
};

pub const OwnedSwitchSelectionDisplay = struct {
    reg: registry.Registry,
    usage_overrides: []?[]const u8,

    pub fn borrowed(self: *@This()) SwitchSelectionDisplay {
        return .{
            .reg = &self.reg,
            .usage_overrides = self.usage_overrides,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.usage_overrides) |usage_override| {
            if (usage_override) |value| allocator.free(value);
        }
        allocator.free(self.usage_overrides);
        self.reg.deinit(allocator);
        self.* = undefined;
    }
};

pub const SwitchLiveController = struct {
    context: *anyopaque,
    maybe_start_refresh: *const fn (context: *anyopaque) anyerror!void,
    maybe_take_updated_display: *const fn (context: *anyopaque) anyerror!?OwnedSwitchSelectionDisplay,
    build_status_line: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
    ) anyerror![]u8,
};

pub const LiveActionOutcome = struct {
    updated_display: OwnedSwitchSelectionDisplay,
    action_message: ?[]u8 = null,
};

pub const SwitchLiveActionController = struct {
    refresh: SwitchLiveController,
    apply_selection: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
        account_key: []const u8,
    ) anyerror!LiveActionOutcome,
    auto_switch: bool = false,
};

pub const RemoveLiveActionController = struct {
    refresh: SwitchLiveController,
    apply_selection: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        display: SwitchSelectionDisplay,
        account_keys: []const []const u8,
    ) anyerror!LiveActionOutcome,
};
