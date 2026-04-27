const std = @import("std");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const terminal_color = @import("../terminal/color.zig");
const service = @import("service.zig");

const RuntimeState = service.RuntimeState;
const queryRuntimeState = service.queryRuntimeState;

pub const Status = struct {
    enabled: bool,
    runtime: RuntimeState,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
    api_account_enabled: bool,
    live_interval_seconds: u16,
};

pub fn helpStateLabel(enabled: bool) []const u8 {
    return if (enabled) "ON" else "OFF";
}

fn colorEnabled() bool {
    return terminal_color.stdoutColorEnabled();
}

pub fn printStatus(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const status = try getStatus(allocator, codex_home);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try writeStatusWithColor(stdout.out(), status, colorEnabled());
}

pub fn getStatus(allocator: std.mem.Allocator, codex_home: []const u8) !Status {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    return .{
        .enabled = reg.auto_switch.enabled,
        .runtime = queryRuntimeState(allocator),
        .threshold_5h_percent = reg.auto_switch.threshold_5h_percent,
        .threshold_weekly_percent = reg.auto_switch.threshold_weekly_percent,
        .api_usage_enabled = reg.api.usage,
        .api_account_enabled = reg.api.account,
        .live_interval_seconds = reg.live.interval_seconds,
    };
}

pub fn writeStatus(out: *std.Io.Writer, status: Status) !void {
    try writeStatusWithColor(out, status, false);
}

fn writeStatusWithColor(out: *std.Io.Writer, status: Status, use_color: bool) !void {
    _ = use_color;
    try out.writeAll("auto-switch: ");
    try out.writeAll(helpStateLabel(status.enabled));
    try out.writeAll("\n");

    try out.writeAll("service: ");
    try out.writeAll(@tagName(status.runtime));
    try out.writeAll("\n");

    try out.writeAll("thresholds: ");
    try out.print(
        "5h<{d}%, weekly<{d}%",
        .{ status.threshold_5h_percent, status.threshold_weekly_percent },
    );
    try out.writeAll("\n");

    try out.writeAll("usage: ");
    try out.writeAll(if (status.api_usage_enabled) "api" else "local");
    try out.writeAll("\n");

    try out.writeAll("account: ");
    try out.writeAll(if (status.api_account_enabled) "api" else "disabled");
    try out.writeAll("\n");

    try out.writeAll("live refresh: ");
    try out.print("{d}s", .{status.live_interval_seconds});
    try out.writeAll("\n");

    try out.flush();
}
