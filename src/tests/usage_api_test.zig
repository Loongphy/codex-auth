const std = @import("std");
const registry = @import("../registry.zig");
const usage_api = @import("../usage_api.zig");

test "parse usage api response maps primary secondary credits and plan" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "plan_type": "pro",
        \\  "rate_limit": {
        \\    "primary_window": {
        \\      "used_percent": 42,
        \\      "limit_window_seconds": 300,
        \\      "reset_at": 123
        \\    },
        \\    "secondary_window": {
        \\      "used_percent": 8,
        \\      "limit_window_seconds": 604800,
        \\      "reset_at": 456
        \\    }
        \\  },
        \\  "credits": {
        \\    "has_credits": true,
        \\    "unlimited": false,
        \\    "balance": "9.99"
        \\  }
        \\}
    ;

    const snapshot = (try usage_api.parseUsageResponse(gpa, body)) orelse return error.TestExpectedEqual;
    defer registry.freeRateLimitSnapshot(gpa, &snapshot);

    try std.testing.expectEqual(registry.PlanType.pro, snapshot.plan_type.?);
    try std.testing.expectEqual(@as(f64, 42.0), snapshot.primary.?.used_percent);
    try std.testing.expectEqual(@as(?i64, 5), snapshot.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?i64, 456), snapshot.secondary.?.resets_at);
    try std.testing.expect(snapshot.credits != null);
    try std.testing.expectEqualStrings("9.99", snapshot.credits.?.balance.?);
}

test "parse usage api response without windows is ignored" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "plan_type": "plus",
        \\  "rate_limit": null,
        \\  "credits": {
        \\    "has_credits": true,
        \\    "unlimited": false,
        \\    "balance": "1.00"
        \\  }
        \\}
    ;

    const snapshot = try usage_api.parseUsageResponse(gpa, body);
    try std.testing.expect(snapshot == null);
}
