const std = @import("std");
const registry = @import("../registry.zig");
const usage_api = @import("../usage_api.zig");

test "parse usage api response maps live usage windows and plan" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "user_id": "user-example",
        \\  "account_id": "account-example",
        \\  "email": "team@example.com",
        \\  "plan_type": "team",
        \\  "rate_limit": {
        \\    "allowed": true,
        \\    "limit_reached": false,
        \\    "primary_window": {
        \\      "used_percent": 11,
        \\      "limit_window_seconds": 18000,
        \\      "reset_after_seconds": 16802,
        \\      "reset_at": 1773491460
        \\    },
        \\    "secondary_window": {
        \\      "used_percent": 94,
        \\      "limit_window_seconds": 604800,
        \\      "reset_after_seconds": 274961,
        \\      "reset_at": 1773749620
        \\    }
        \\  },
        \\  "code_review_rate_limit": {
        \\    "allowed": true,
        \\    "limit_reached": false,
        \\    "primary_window": {
        \\      "used_percent": 0,
        \\      "limit_window_seconds": 604800,
        \\      "reset_after_seconds": 604800,
        \\      "reset_at": 1774079459
        \\    },
        \\    "secondary_window": null
        \\  },
        \\  "additional_rate_limits": null,
        \\  "credits": {
        \\    "has_credits": false,
        \\    "unlimited": false,
        \\    "balance": null,
        \\    "approx_local_messages": null,
        \\    "approx_cloud_messages": null
        \\  },
        \\  "promo": null
        \\}
    ;

    const snapshot = (try usage_api.parseUsageResponse(gpa, body)) orelse return error.TestExpectedEqual;
    defer registry.freeRateLimitSnapshot(gpa, &snapshot);

    try std.testing.expectEqual(registry.PlanType.team, snapshot.plan_type.?);
    try std.testing.expectEqual(@as(f64, 11.0), snapshot.primary.?.used_percent);
    try std.testing.expectEqual(@as(?i64, 300), snapshot.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?i64, 10080), snapshot.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?i64, 1773749620), snapshot.secondary.?.resets_at);
    try std.testing.expect(snapshot.credits != null);
    try std.testing.expect(!snapshot.credits.?.has_credits);
    try std.testing.expect(snapshot.credits.?.balance == null);
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
