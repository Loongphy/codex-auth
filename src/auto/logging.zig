const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const registry = @import("../registry/root.zig");
const c_time = @cImport({
    @cInclude("time.h");
});

pub fn writeAutoSwitchLogLine(
    out: *std.Io.Writer,
    from: *const registry.AccountRecord,
    to: *const registry.AccountRecord,
) !void {
    try out.print("[switch] {s} -> {s}\n", .{ from.email, to.email });
    try out.flush();
}

pub fn emitAutoSwitchLog(from: *const registry.AccountRecord, to: *const registry.AccountRecord) void {
    var stderr_buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &stderr_buffer);
    writeAutoSwitchLogLine(&writer.interface, from, to) catch {};
}

pub const DaemonLogPriority = enum {
    err,
    warning,
    notice,
    info,
    debug,
};

pub fn emitDaemonLog(priority: DaemonLogPriority, comptime fmt: []const u8, args: anytype) void {
    _ = priority;
    var stderr_buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &stderr_buffer);
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

pub fn emitTaggedDaemonLog(
    priority: DaemonLogPriority,
    tag: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = priority;
    var stderr_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &stderr_buffer);
    writer.interface.print("[{s}] ", .{tag}) catch {};
    writer.interface.print(fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn percentLabel(buf: *[5]u8, value: ?i64) []const u8 {
    const percent = value orelse return "-";
    const clamped = @min(@max(percent, 0), 100);
    return std.fmt.bufPrint(buf, "{d}%", .{clamped}) catch "-";
}

pub fn localDateTimeLabel(buf: *[19]u8, timestamp_ms: i64) []const u8 {
    const seconds = @divTrunc(timestamp_ms, std.time.ms_per_s);
    var tm: c_time.struct_tm = undefined;
    if (!localtimeCompat(seconds, &tm)) return "-";
    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    }) catch "-";
}

pub fn rolloutFileLabel(buf: *[96]u8, path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return std.fmt.bufPrint(buf, "{s}", .{basename}) catch basename;
}

fn localtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_localtime64_s") and @hasDecl(c_time, "__time64_t")) {
            var t64 = std.math.cast(c_time.__time64_t, ts) orelse return false;
            return c_time._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c_time.time_t, ts) orelse return false;
    if (comptime @hasDecl(c_time, "localtime_r")) {
        return c_time.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c_time, "localtime")) {
        const tm_ptr = c_time.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn windowDurationLabel(buf: *[16]u8, window_minutes: ?i64) []const u8 {
    const minutes = window_minutes orelse return "unlabeled";
    if (minutes <= 0) return "unlabeled";
    if (@mod(minutes, 24 * 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}d", .{@divExact(minutes, 24 * 60)}) catch "unlabeled";
    }
    if (@mod(minutes, 60) == 0) {
        return std.fmt.bufPrint(buf, "{d}h", .{@divExact(minutes, 60)}) catch "unlabeled";
    }
    return std.fmt.bufPrint(buf, "{d}m", .{minutes}) catch "unlabeled";
}

fn windowSnapshotLabel(buf: *[32]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "-";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}@{s}", .{
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
        windowDurationLabel(&duration_buf, resolved.window_minutes),
    }) catch "-";
}

fn windowUsageEntryLabel(buf: *[24]u8, window: ?registry.RateLimitWindow, now: i64) []const u8 {
    const resolved = window orelse return "";
    var percent_buf: [5]u8 = undefined;
    var duration_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}={s}", .{
        windowDurationLabel(&duration_buf, resolved.window_minutes),
        percentLabel(&percent_buf, registry.remainingPercentAt(resolved, now)),
    }) catch "";
}

pub fn rolloutWindowsLabel(buf: *[64]u8, snapshot: registry.RateLimitSnapshot, now: i64) []const u8 {
    var primary_buf: [24]u8 = undefined;
    var secondary_buf: [24]u8 = undefined;
    const primary = windowUsageEntryLabel(&primary_buf, snapshot.primary, now);
    const secondary = windowUsageEntryLabel(&secondary_buf, snapshot.secondary, now);

    if (primary.len != 0 and secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s} {s}", .{ primary, secondary }) catch primary;
    }
    if (primary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{primary}) catch "no-usage-limits-window";
    }
    if (secondary.len != 0) {
        return std.fmt.bufPrint(buf, "{s}", .{secondary}) catch "no-usage-limits-window";
    }
    return "no-usage-limits-window";
}

pub fn apiStatusLabel(buf: *[24]u8, status_code: ?u16, has_usage_windows: bool, missing_auth: bool) []const u8 {
    if (missing_auth) return "MissingAuth";
    if (status_code) |status| {
        if (status == 200 and !has_usage_windows) return "NoUsageLimitsWindow";
        return std.fmt.bufPrint(buf, "{d}", .{status}) catch "-";
    }
    return if (has_usage_windows) "-" else "NoUsageLimitsWindow";
}

pub fn fieldSeparator() []const u8 {
    return " | ";
}
