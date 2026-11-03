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

pub fn formatRateLimitFullAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try allocator.print( "-", .{});
    if (window.?.resets_at == null) return try allocator.print( "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try allocator.print( "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return allocator.print( "{d}% ({s})", .{ remaining, parts.time });
    }
    return allocator.print( "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

pub fn formatRateLimitUiAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow, width: usize) ![]u8 {
    if (window == null) return try allocator.print( "-", .{});
    if (window.?.resets_at == null) return try allocator.print( "-", .{});
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try allocator.print( "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);

    const candidates_same = [_][]const u8{
        try allocator.print( "{d}% ({s})", .{ remaining, parts.time }),
        try allocator.print( "{d}%", .{remaining}),
    };
    defer allocator.free(candidates_same[0]);
    defer allocator.free(candidates_same[1]);

    if (parts.same_day) {
        if (width >= candidates_same[0].len or width == 0) return allocator.print( "{s}", .{candidates_same[0]});
        return allocator.print( "{s}", .{candidates_same[1]});
    }

    const candidate_full = try allocator.print( "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
    defer allocator.free(candidate_full);
    const candidate_date = try allocator.print( "{d}% ({s})", .{ remaining, parts.date });
    defer allocator.free(candidate_date);
    const candidate_time = try allocator.print( "{d}% ({s})", .{ remaining, parts.time });
    defer allocator.free(candidate_time);
    const candidate_percent = try allocator.print( "{d}%", .{remaining});
    defer allocator.free(candidate_percent);

    if (width >= candidate_full.len or width == 0) return allocator.print( "{s}", .{candidate_full});
    if (width >= candidate_date.len) return allocator.print( "{s}", .{candidate_date});
    if (width >= candidate_time.len) return allocator.print( "{s}", .{candidate_time});
    return allocator.print( "{s}", .{candidate_percent});
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64) !ResetParts {
    var tm: localtime.struct_tm = undefined;
    if (!localtime.compat(reset_at, &tm)) {
        return ResetParts{
            .time = try allocator.print( "-", .{}),
            .date = try allocator.print( "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: localtime.struct_tm = undefined;
    if (!localtime.compat(now, &now_tm)) {
        return ResetParts{
            .time = try allocator.print( "-", .{}),
            .date = try allocator.print( "-", .{}),
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
        .time = try allocator.print( "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try allocator.print( "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}



fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}
