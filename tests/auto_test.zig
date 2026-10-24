const std = @import("std");
const pkg = @import("codex_auth");
const registry = pkg.registry;
const auto = pkg.workflows.auto;
const usage = pkg.workflows;
const fixtures = @import("support/fixtures.zig");
const gpa = std.testing.allocator;

fn fresh() usage.ForegroundUsageOutcome {
    return .{ .attempted = true, .method = .api, .status_code = 200, .received_snapshot = true };
}

fn seed(reg: *registry.Registry, email: []const u8, primary: f64, weekly: f64) !void {
    try fixtures.appendAccount(gpa, reg, email, "", .plus);
    const rec = &reg.accounts.items[reg.accounts.items.len - 1];
    rec.last_usage = .{
        .primary = .{ .used_percent = primary, .window_minutes = 300, .resets_at = 10000 },
        .secondary = .{ .used_percent = weekly, .window_minutes = 10080, .resets_at = 20000 },
        .credits = null,
        .plan_type = .plus,
    };
}

fn setup() !registry.Registry {
    var reg = fixtures.makeEmptyRegistry();
    errdefer reg.deinit(gpa);
    try seed(&reg, "current@example.com", 90, 20);
    try seed(&reg, "next@example.com", 10, 30);
    try seed(&reg, "best@example.com", 20, 20);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    reg.active_account_activated_at_ms = 0;
    return reg;
}

const outcomes = [_]usage.ForegroundUsageOutcome{ fresh(), fresh(), fresh() };

test "auto selects most remaining quota across both windows at threshold" {
    var reg = try setup();
    defer reg.deinit(gpa);
    const decision = auto.evaluate(&reg, &outcomes, .{}, 1000000);
    try std.testing.expectEqual(.would_switch, decision.status);
    try std.testing.expectEqual(@as(?usize, 2), decision.target);
    reg.accounts.items[0].last_usage.?.primary.?.used_percent = 89.9;
    try std.testing.expectEqual(.held, auto.evaluate(&reg, &outcomes, .{}, 1000000).status);
    reg.accounts.items[0].last_usage.?.secondary.?.used_percent = 95;
    try std.testing.expectEqual(.would_switch, auto.evaluate(&reg, &outcomes, .{}, 1000000).status);
}

test "auto honors activation cooldown and explicit zero cooldown" {
    var reg = try setup();
    defer reg.deinit(gpa);
    reg.active_account_activated_at_ms = 990000;
    try std.testing.expectEqual(.cooldown, auto.evaluate(&reg, &outcomes, .{}, 1000000).status);
    try std.testing.expectEqual(.would_switch, auto.evaluate(&reg, &outcomes, .{ .cooldown_seconds = 0 }, 1000000).status);
    try std.testing.expectEqual(.would_switch, auto.evaluate(&reg, &outcomes, .{}, 1290000).status);
}

test "auto rejects stale failed missing invalid and API key candidates" {
    var reg = try setup();
    defer reg.deinit(gpa);
    var states = outcomes;
    states[2].status_code = 401;
    try std.testing.expectEqual(@as(?usize, 1), auto.evaluate(&reg, &states, .{}, 1000000).target);
    states[1].received_snapshot = false;
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &states, .{}, 1000000).status);
    states = outcomes;
    reg.accounts.items[2].auth_mode = .apikey;
    reg.accounts.items[1].last_usage.?.primary.?.resets_at = 999;
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &states, .{}, 1000000).status);
    reg.accounts.items[1].last_usage.?.primary.?.resets_at = 10000;
    reg.accounts.items[1].last_usage.?.primary.?.used_percent = std.math.nan(f64);
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &states, .{}, 1000000).status);
    reg.accounts.items[1].last_usage.?.primary.?.used_percent = -1;
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &states, .{}, 1000000).status);
}

test "auto holds safely when current usage is unknown or every target is over threshold" {
    var reg = try setup();
    defer reg.deinit(gpa);
    var states = outcomes;
    states[0].error_name = "NetworkError";
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &states, .{}, 1000000).status);
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &.{}, .{}, 1000000).status);
    reg.accounts.items[1].last_usage.?.primary.?.used_percent = 90;
    reg.accounts.items[2].last_usage.?.secondary.?.used_percent = 100;
    try std.testing.expectEqual(.blocked, auto.evaluate(&reg, &outcomes, .{}, 1000000).status);
}

test "auto parser accepts controls and rejects invalid and duplicate values" {
    const args = [_][:0]const u8{ "codex-auth", "auto", "--once", "--dry-run", "--json", "--threshold", "85.5", "--interval", "15", "--cooldown", "0" };
    var parsed = try pkg.cli.commands.parseArgs(gpa, &args);
    defer pkg.cli.commands.freeParseResult(gpa, &parsed);
    const opts = parsed.command.auto;
    try std.testing.expect(opts.once and opts.dry_run and opts.json);
    try std.testing.expectEqual(@as(f64, 85.5), opts.threshold);
    try std.testing.expectEqual(@as(u16, 15), opts.interval_seconds);
    try std.testing.expectEqual(@as(u32, 0), opts.cooldown_seconds);
    for ([_][]const [:0]const u8{
        &.{ "codex-auth", "auto", "--once", "--once" },
        &.{ "codex-auth", "auto", "--threshold", "nan", "--json" },
        &.{ "codex-auth", "auto", "--threshold", "100" },
        &.{ "codex-auth", "auto", "--interval", "14" },
        &.{ "codex-auth", "auto", "--cooldown", "-1" },
        &.{ "codex-auth", "auto", "--cooldown", "86401" },
        &.{ "codex-auth", "auto", "--threshold" },
        &.{ "codex-auth", "auto", "--restart-daemon" },
        &.{ "codex-auth", "auto", "--skip-api" },
    }) |invalid| {
        var result = try pkg.cli.commands.parseArgs(gpa, invalid);
        defer pkg.cli.commands.freeParseResult(gpa, &result);
        try std.testing.expect(result == .usage_error);
    }
}

test "read-only registry loading rejects migrations without rewriting files" {
    const fs = pkg.core.compat_fs;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("accounts");
    const data = "{\"schema_version\":3,\"active_account_key\":null,\"accounts\":[]}";
    try tmp.dir.writeFile(.{ .sub_path = "accounts/registry.json", .data = data });
    const home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(home);
    try std.testing.expectError(error.RegistryMigrationRequired, registry.loadRegistryReadOnly(gpa, home));
    const path = try registry.registryPath(gpa, home);
    defer gpa.free(path);
    const after = try fixtures.readFileAlloc(gpa, path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(data, after);
}
