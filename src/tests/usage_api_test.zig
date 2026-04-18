const std = @import("std");
const fs = @import("../compat_fs.zig");
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

test "parse usage api response maps prolite plan" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "plan_type": "prolite",
        \\  "rate_limit": {
        \\    "allowed": true,
        \\    "limit_reached": false,
        \\    "primary_window": {
        \\      "used_percent": 7,
        \\      "limit_window_seconds": 18000,
        \\      "reset_after_seconds": 1200,
        \\      "reset_at": 1773491460
        \\    },
        \\    "secondary_window": null
        \\  }
        \\}
    ;

    const snapshot = (try usage_api.parseUsageResponse(gpa, body)) orelse return error.TestExpectedEqual;
    defer registry.freeRateLimitSnapshot(gpa, &snapshot);

    try std.testing.expectEqual(registry.PlanType.prolite, snapshot.plan_type.?);
}

test "fetch usage for auth path groups non-chatgpt or incomplete auth as missing auth" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data =
            \\{
            \\  "OPENAI_API_KEY": "sk-test"
            \\}
        ,
    });

    const auth_path = try tmp.dir.realpathAlloc(gpa, "auth.json");
    defer gpa.free(auth_path);

    const result = try usage_api.fetchUsageForAuthPathDetailed(gpa, auth_path);
    try std.testing.expect(result.snapshot == null);
    try std.testing.expect(result.status_code == null);
    try std.testing.expect(result.missing_auth);
}
