const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const localtime = @import("../time/localtime.zig");

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts, allocator: std.mem.Allocator) void {
        allocator.free(self.time);
        allocator.free(self.date);
    }
};

/// Single source of truth is `registry.resolveRateWindow`; this alias keeps
/// the TUI call sites on the same resolution without a second implementation.
pub const resolveRateWindow = registry.resolveRateWindow;

/// Display-facing usage cell. Only the last-measured remaining percent is
/// shown: the "elapsed `resets_at` means refilled" inference in
/// `registry.remainingPercentAt` exists for auto-switch scoring and must not
/// turn a stale snapshot into a fake full quota. Without a real future
/// `resets_at` (missing, `<= 0`, or already elapsed) the cell shows the
/// measured percent plus a stale marker instead of a reset time.
pub fn formatRateLimitFullAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    const remaining = registry.measuredRemainingPercent(window) orelse
        return try allocator.print("-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at orelse
        return allocator.print("{d}% (stale)", .{remaining});
    if (reset_at <= 0 or now >= reset_at) {
        return allocator.print("{d}% (stale)", .{remaining});
    }
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return allocator.print("{d}% ({s})", .{ remaining, parts.time });
    }
    return allocator.print("{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64) !ResetParts {
    var tm: localtime.struct_tm = undefined;
    if (!localtime.compat(reset_at, &tm)) {
        return ResetParts{
            .time = try allocator.print("-", .{}),
            .date = try allocator.print("-", .{}),
            .same_day = true,
        };
    }
    var now_tm: localtime.struct_tm = undefined;
    if (!localtime.compat(now, &now_tm)) {
        return ResetParts{
            .time = try allocator.print("-", .{}),
            .date = try allocator.print("-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try allocator.print("{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try allocator.print("{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

