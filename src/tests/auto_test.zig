const std = @import("std");
const time_compat = @import("../compat_time.zig");
const fs = @import("../compat_fs.zig");
const account_api = @import("../account_api.zig");
const auto = @import("../auto.zig");
const registry = @import("../registry.zig");
const usage_api = @import("../usage_api.zig");
const bdd = @import("bdd_helpers.zig");

const rollout_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:00Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":92.0,\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":49.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}";
const null_rate_limits_rollout_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:01Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}";
const empty_rate_limits_rollout_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:02Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{}}}";
var daemon_api_fetch_count: usize = 0;
var candidate_api_fetch_count: usize = 0;
var daemon_account_name_fetch_count: usize = 0;
var daemon_account_name_fetch_registry_rewrite_codex_home: ?[]const u8 = null;
var candidate_high_auth_path: ?[]const u8 = null;
var candidate_low_auth_path: ?[]const u8 = null;
var candidate_reject_auth_path: ?[]const u8 = null;
const daemon_grouped_user_id = "user-auto-grouped";
const daemon_primary_account_id = "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";
const daemon_secondary_account_id = "518a44d9-ba75-4bad-87e5-ae9377042960";

fn appendGroupedAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
    email: []const u8,
    plan: registry.PlanType,
) !void {
    const record_key = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
    errdefer allocator.free(record_key);

    try reg.accounts.append(allocator, .{
        .account_key = record_key,
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, ""),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = time_compat.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn authJsonWithIds(
    allocator: std.mem.Allocator,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) ![]u8 {
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);

    const header_b64 = try bdd.b64url(allocator, header);
    defer allocator.free(header_b64);
    const payload_b64 = try bdd.b64url(allocator, payload);
    defer allocator.free(payload_b64);
    const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ header_b64, ".", payload_b64, ".sig" });
    defer allocator.free(jwt);

    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"access-{s}\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, jwt },
    );
}

fn writeActiveAuthWithIds(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) !void {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const auth_json = try authJsonWithIds(allocator, email, plan, chatgpt_user_id, chatgpt_account_id);
    defer allocator.free(auth_json);
    try fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn writeAccountSnapshotWithIds(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) !void {
    const account_key = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
    defer allocator.free(account_key);

    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const auth_json = try authJsonWithIds(allocator, email, plan, chatgpt_user_id, chatgpt_account_id);
    defer allocator.free(auth_json);
    try fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn resetDaemonAccountNameFetcher() void {
    daemon_account_name_fetch_count = 0;
    daemon_account_name_fetch_registry_rewrite_codex_home = null;
}

fn buildGroupedAccountNamesFetchResult(allocator: std.mem.Allocator) !account_api.FetchResult {
    const entries = try allocator.alloc(account_api.AccountEntry, 2);
    errdefer allocator.free(entries);

    entries[0] = .{
        .account_id = try allocator.dupe(u8, daemon_primary_account_id),
        .account_name = try allocator.dupe(u8, "Primary Workspace"),
    };
    errdefer entries[0].deinit(allocator);
    entries[1] = .{
        .account_id = try allocator.dupe(u8, daemon_secondary_account_id),
        .account_name = try allocator.dupe(u8, "Backup Workspace"),
    };
    errdefer entries[1].deinit(allocator);

    return .{
        .entries = entries,
        .status_code = 200,
    };
}

fn fetchGroupedAccountNames(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    _ = access_token;
    _ = account_id;
    daemon_account_name_fetch_count += 1;

    return buildGroupedAccountNamesFetchResult(allocator);
}

fn fetchGroupedAccountNamesAfterConcurrentUsageDisable(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    _ = access_token;
    _ = account_id;
    daemon_account_name_fetch_count += 1;

    const codex_home = daemon_account_name_fetch_registry_rewrite_codex_home orelse return error.TestMissingCodexHome;
    var latest = try registry.loadRegistry(allocator, codex_home);
    defer latest.deinit(allocator);
    latest.api.usage = false;
    try registry.saveRegistry(allocator, codex_home, &latest);

    return buildGroupedAccountNamesFetchResult(allocator);
}

test "Scenario: Given auto-switch daemon with missing grouped account names when it detects the active scope then it refreshes and saves them" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = false;
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_primary_account_id, "group@example.com", .team);
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_secondary_account_id, "group@example.com", .team);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeActiveAuthWithIds(gpa, codex_home, "group@example.com", "team", daemon_grouped_user_id, daemon_primary_account_id);

    resetDaemonAccountNameFetcher();
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);
    try std.testing.expect(try auto.daemonCycleWithAccountNameFetcherForTest(
        gpa,
        codex_home,
        &refresh_state,
        fetchGroupedAccountNames,
    ));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), daemon_account_name_fetch_count);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[1].account_name.?);

    try std.testing.expect(try auto.daemonCycleWithAccountNameFetcherForTest(
        gpa,
        codex_home,
        &refresh_state,
        fetchGroupedAccountNames,
    ));
    try std.testing.expectEqual(@as(usize, 1), daemon_account_name_fetch_count);
}

test "Scenario: Given auto-switch disabled when account names are missing then the daemon skips grouped name refresh" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = false;
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_primary_account_id, "group@example.com", .team);
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_secondary_account_id, "group@example.com", .team);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);

    resetDaemonAccountNameFetcher();
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);
    try std.testing.expect(!(try auto.refreshActiveAccountNamesForDaemonWithFetcher(
        gpa,
        codex_home,
        &reg,
        &refresh_state,
        fetchGroupedAccountNames,
    )));
    try std.testing.expectEqual(@as(usize, 0), daemon_account_name_fetch_count);
}

test "Scenario: Given daemon account-name refresh when registry changes during fetch then it merges onto the latest registry" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;
    reg.api.account = true;
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_primary_account_id, "group@example.com", .team);
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_secondary_account_id, "group@example.com", .team);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeActiveAuthWithIds(gpa, codex_home, "group@example.com", "team", daemon_grouped_user_id, daemon_primary_account_id);

    const rewrite_codex_home = try gpa.dupe(u8, codex_home);
    defer gpa.free(rewrite_codex_home);
    resetDaemonAccountNameFetcher();
    daemon_account_name_fetch_registry_rewrite_codex_home = rewrite_codex_home;
    defer daemon_account_name_fetch_registry_rewrite_codex_home = null;

    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);
    try std.testing.expect(try auto.daemonCycleWithAccountNameFetcherForTest(
        gpa,
        codex_home,
        &refresh_state,
        fetchGroupedAccountNamesAfterConcurrentUsageDisable,
    ));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), daemon_account_name_fetch_count);
    try std.testing.expect(!loaded.api.usage);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[1].account_name.?);
}

test "Scenario: Given auto-switch daemon with only another user missing grouped account names when it runs then it refreshes that stored scope too" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = false;
    reg.api.account = true;
    try appendGroupedAccount(gpa, &reg, "user-active", "acct-active-a", "active@example.com", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Active Workspace");
    try appendGroupedAccount(gpa, &reg, "user-active", "acct-active-b", "active@example.com", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Active Backup");
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_primary_account_id, "group@example.com", .team);
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_secondary_account_id, "group@example.com", .team);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeActiveAuthWithIds(gpa, codex_home, "active@example.com", "team", "user-active", "acct-active-a");
    try writeAccountSnapshotWithIds(gpa, codex_home, "group@example.com", "team", daemon_grouped_user_id, daemon_primary_account_id);

    resetDaemonAccountNameFetcher();
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);
    try std.testing.expect(try auto.daemonCycleWithAccountNameFetcherForTest(
        gpa,
        codex_home,
        &refresh_state,
        fetchGroupedAccountNames,
    ));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), daemon_account_name_fetch_count);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[2].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[3].account_name.?);
}

test "Scenario: Given auto-switch daemon with grouped team names and only a stored plus snapshot for the same user when it runs then it updates the team records" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = false;
    reg.api.account = true;
    try appendGroupedAccount(gpa, &reg, "user-active", "acct-active-a", "active@example.com", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Active Workspace");
    try appendGroupedAccount(gpa, &reg, "user-active", "acct-active-b", "active@example.com", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Active Backup");
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_primary_account_id, "group@example.com", .team);
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, daemon_secondary_account_id, "group@example.com", .team);
    reg.accounts.items[3].account_name = try gpa.dupe(u8, "Old Backup Workspace");
    try appendGroupedAccount(gpa, &reg, daemon_grouped_user_id, "acct-plus", "group@example.com", .plus);
    try registry.setActiveAccountKey(gpa, &reg, reg.accounts.items[0].account_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeActiveAuthWithIds(gpa, codex_home, "active@example.com", "team", "user-active", "acct-active-a");
    try writeAccountSnapshotWithIds(gpa, codex_home, "group@example.com", "plus", daemon_grouped_user_id, "acct-plus");

    resetDaemonAccountNameFetcher();
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);
    try std.testing.expect(try auto.daemonCycleWithAccountNameFetcherForTest(
        gpa,
        codex_home,
        &refresh_state,
        fetchGroupedAccountNames,
    ));

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), daemon_account_name_fetch_count);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[2].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[3].account_name.?);
    try std.testing.expect(loaded.accounts.items[4].account_name == null);
}

fn appendAccountWithUsage(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    email: []const u8,
    usage: ?registry.RateLimitSnapshot,
    last_usage_at: ?i64,
) !void {
    try bdd.appendAccount(allocator, reg, email, "", null);
    const idx = reg.accounts.items.len - 1;
    reg.accounts.items[idx].last_usage = usage;
    reg.accounts.items[idx].last_usage_at = last_usage_at;
}

fn apiSnapshot() registry.RateLimitSnapshot {
    return .{
        .primary = .{ .used_percent = 15.0, .window_minutes = 300, .resets_at = 1000 },
        .secondary = .{ .used_percent = 4.0, .window_minutes = 10080, .resets_at = 2000 },
        .credits = null,
        .plan_type = .pro,
    };
}

fn fetchApiSnapshot(_: std.mem.Allocator, _: []const u8) !?registry.RateLimitSnapshot {
    return apiSnapshot();
}

fn fetchApiError(_: std.mem.Allocator, _: []const u8) !?registry.RateLimitSnapshot {
    return error.TestApiUnavailable;
}

fn fetchCountingApiSnapshot(_: std.mem.Allocator, _: []const u8) !?registry.RateLimitSnapshot {
    daemon_api_fetch_count += 1;
    return apiSnapshot();
}

fn fetchCountingApiError(_: std.mem.Allocator, _: []const u8) !?registry.RateLimitSnapshot {
    daemon_api_fetch_count += 1;
    return error.TestApiUnavailable;
}

fn fetchCandidateUsageByAuthPathDetailed(_: std.mem.Allocator, auth_path: []const u8) !usage_api.UsageFetchResult {
    if (candidate_high_auth_path) |path| {
        if (std.mem.eql(u8, auth_path, path)) {
            return .{
                .snapshot = .{
                    .primary = .{ .used_percent = 12.0, .window_minutes = 300, .resets_at = null },
                    .secondary = .{ .used_percent = 7.0, .window_minutes = 10080, .resets_at = null },
                    .credits = null,
                    .plan_type = .pro,
                },
                .status_code = 200,
            };
        }
    }
    if (candidate_low_auth_path) |path| {
        if (std.mem.eql(u8, auth_path, path)) {
            return .{
                .snapshot = .{
                    .primary = .{ .used_percent = 96.0, .window_minutes = 300, .resets_at = null },
                    .secondary = .{ .used_percent = 60.0, .window_minutes = 10080, .resets_at = null },
                    .credits = null,
                    .plan_type = .pro,
                },
                .status_code = 200,
            };
        }
    }
    if (candidate_reject_auth_path) |path| {
        if (std.mem.eql(u8, auth_path, path)) {
            return .{ .snapshot = null, .status_code = 403 };
        }
    }
    return .{ .snapshot = null, .status_code = null };
}

fn fetchCandidateUsageByAuthPath(allocator: std.mem.Allocator, auth_path: []const u8) !?registry.RateLimitSnapshot {
    const result = try fetchCandidateUsageByAuthPathDetailed(allocator, auth_path);
    return result.snapshot;
}

fn fetchCountingCandidateUsageByAuthPathDetailed(allocator: std.mem.Allocator, auth_path: []const u8) !usage_api.UsageFetchResult {
    candidate_api_fetch_count += 1;
    return fetchCandidateUsageByAuthPathDetailed(allocator, auth_path);
}

fn fetchCandidateUsageHttp403(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
    candidate_api_fetch_count += 1;
    return .{ .snapshot = null, .status_code = 403 };
}

fn fetchCandidateUsageNoWindow200(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
    candidate_api_fetch_count += 1;
    return .{ .snapshot = null, .status_code = 200 };
}

fn fetchCandidateUsageUnavailable(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
    candidate_api_fetch_count += 1;
    return error.TestApiUnavailable;
}

fn fetchCandidateUsageMissingAuth(_: std.mem.Allocator, _: []const u8) !usage_api.UsageFetchResult {
    candidate_api_fetch_count += 1;
    return .{ .snapshot = null, .status_code = null, .missing_auth = true };
}

fn partialServiceArtifactPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "partial-service-artifact" });
}

fn installServiceWithPartialArtifact(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    _: []const u8,
) !void {
    const artifact_path = try partialServiceArtifactPath(allocator, codex_home);
    defer allocator.free(artifact_path);
    try fs.cwd().writeFile(.{ .sub_path = artifact_path, .data = "partial" });
    return error.TestInstallFailed;
}

fn uninstallPartialServiceArtifact(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const artifact_path = try partialServiceArtifactPath(allocator, codex_home);
    defer allocator.free(artifact_path);
    fs.cwd().deleteFile(artifact_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn preflightFailure(_: std.mem.Allocator) !void {
    return error.TestPreflightFailed;
}

fn preflightSuccess(_: std.mem.Allocator) !void {}

test "Scenario: Given no-snapshot account when selecting auto candidate then it is treated as fresh quota" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 20.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "known@example.com", .{
        .primary = .{ .used_percent = 40.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    }, 200);
    try appendAccountWithUsage(gpa, &reg, "fresh@example.com", null, null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const idx = auto.bestAutoSwitchCandidateIndex(&reg, time_compat.timestamp()) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[idx].email, "fresh@example.com"));
}

test "Scenario: Given free candidate with only a primary weekly window when selecting auto candidate then it remains eligible" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 30.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "pro@example.com", .{
        .primary = .{ .used_percent = 80.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 70.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 200);
    try appendAccountWithUsage(gpa, &reg, "free@example.com", .{
        .primary = .{ .used_percent = 40.0, .window_minutes = 10080, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .free,
    }, 300);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const idx = auto.bestAutoSwitchCandidateIndex(&reg, time_compat.timestamp()) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[idx].email, "free@example.com"));
}

test "Scenario: Given free candidate with only a secondary weekly window when selecting auto candidate then it remains eligible" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 30.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "pro@example.com", .{
        .primary = .{ .used_percent = 85.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 80.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 200);
    try appendAccountWithUsage(gpa, &reg, "free@example.com", .{
        .primary = null,
        .secondary = .{ .used_percent = 45.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .free,
    }, 300);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const idx = auto.bestAutoSwitchCandidateIndex(&reg, time_compat.timestamp()) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[idx].email, "free@example.com"));
}

test "Scenario: Given free account with only a weekly window when checking current then the free 5h guard does not misfire" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "free@example.com", .{
        .primary = .{ .used_percent = 66.0, .window_minutes = 10080, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .free,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "free@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(!auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given weekly remaining below threshold when checking current then auto switch is required" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 20.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 97.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given custom 5h threshold when checking current then it uses configured value" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.threshold_5h_percent = 15;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 88.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 40.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given missing window_minutes in the primary slot when checking current then 5h fallback still triggers auto switch" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = null, .resets_at = null },
        .secondary = .{ .used_percent = 20.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given free account near exhaustion when checking current then realtime guard switches earlier than the configured threshold" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try appendAccountWithUsage(gpa, &reg, "free@example.com", .{
        .primary = .{ .used_percent = 70.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 20.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .free,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "free@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given stricter weekly threshold when checking current then default trigger can be suppressed" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.threshold_weekly_percent = 3;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 20.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 96.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(!auto.shouldSwitchCurrent(&reg, time_compat.timestamp()));
}

test "Scenario: Given threshold overrides when applying config then unspecified values stay unchanged" {
    var cfg = registry.defaultAutoSwitchConfig();
    cfg.threshold_5h_percent = 11;
    cfg.threshold_weekly_percent = 7;

    auto.applyThresholdConfig(&cfg, .{
        .threshold_5h_percent = 13,
        .threshold_weekly_percent = null,
    });

    try std.testing.expect(cfg.threshold_5h_percent == 13);
    try std.testing.expect(cfg.threshold_weekly_percent == 7);
}

test "Scenario: Given better candidate when auto switch runs then auth and active account move silently" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;

    try appendAccountWithUsage(gpa, &reg, "low@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "fresh@example.com", null, null);
    const low_account_id = try bdd.accountKeyForEmailAlloc(gpa, "low@example.com");
    defer gpa.free(low_account_id);
    try registry.setActiveAccountKey(gpa, &reg, low_account_id);

    const low_auth = try bdd.authJsonWithEmailPlan(gpa, "low@example.com", "pro");
    defer gpa.free(low_auth);
    const fresh_auth = try bdd.authJsonWithEmailPlan(gpa, "fresh@example.com", "pro");
    defer gpa.free(fresh_auth);

    const low_path = try registry.accountAuthPath(gpa, codex_home, low_account_id);
    defer gpa.free(low_path);
    const fresh_account_id = try bdd.accountKeyForEmailAlloc(gpa, "fresh@example.com");
    defer gpa.free(fresh_account_id);
    const fresh_path = try registry.accountAuthPath(gpa, codex_home, fresh_account_id);
    defer gpa.free(fresh_path);
    const active_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_path);

    try fs.cwd().writeFile(.{ .sub_path = low_path, .data = low_auth });
    try fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });
    try fs.cwd().writeFile(.{ .sub_path = active_path, .data = low_auth });

    try std.testing.expect(try auto.maybeAutoSwitch(gpa, codex_home, &reg));
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, fresh_account_id));

    const active_data = try bdd.readFileAlloc(gpa, active_path);
    defer gpa.free(active_data);
    try std.testing.expect(std.mem.eql(u8, active_data, fresh_auth));
}

test "Scenario: Given API mode and unknown candidate usage when auto switching then it refreshes the candidate before switching" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "low@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "fresh@example.com", null, null);
    const low_account_id = try bdd.accountKeyForEmailAlloc(gpa, "low@example.com");
    defer gpa.free(low_account_id);
    try registry.setActiveAccountKey(gpa, &reg, low_account_id);

    const fresh_account_id = try bdd.accountKeyForEmailAlloc(gpa, "fresh@example.com");
    defer gpa.free(fresh_account_id);
    const low_auth = try bdd.authJsonWithEmailPlan(gpa, "low@example.com", "pro");
    defer gpa.free(low_auth);
    const fresh_auth = try bdd.authJsonWithEmailPlan(gpa, "fresh@example.com", "pro");
    defer gpa.free(fresh_auth);
    const low_path = try registry.accountAuthPath(gpa, codex_home, low_account_id);
    defer gpa.free(low_path);
    const fresh_path = try registry.accountAuthPath(gpa, codex_home, fresh_account_id);
    defer gpa.free(fresh_path);
    const active_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_path);
    try fs.cwd().writeFile(.{ .sub_path = low_path, .data = low_auth });
    try fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });
    try fs.cwd().writeFile(.{ .sub_path = active_path, .data = low_auth });

    candidate_high_auth_path = try gpa.dupe(u8, fresh_path);
    defer {
        gpa.free(candidate_high_auth_path.?);
        candidate_high_auth_path = null;
    }

    const attempt = try auto.maybeAutoSwitchWithUsageFetcher(gpa, codex_home, &reg, fetchCandidateUsageByAuthPath);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, fresh_account_id));
}

test "Scenario: Given API mode and poor refreshed candidate when auto switching then it stays on the current account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "low@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "fresh@example.com", null, null);
    const low_account_id = try bdd.accountKeyForEmailAlloc(gpa, "low@example.com");
    defer gpa.free(low_account_id);
    try registry.setActiveAccountKey(gpa, &reg, low_account_id);

    const fresh_account_id = try bdd.accountKeyForEmailAlloc(gpa, "fresh@example.com");
    defer gpa.free(fresh_account_id);
    const fresh_auth = try bdd.authJsonWithEmailPlan(gpa, "fresh@example.com", "pro");
    defer gpa.free(fresh_auth);
    const fresh_path = try registry.accountAuthPath(gpa, codex_home, fresh_account_id);
    defer gpa.free(fresh_path);
    try fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });

    candidate_low_auth_path = try gpa.dupe(u8, fresh_path);
    defer {
        gpa.free(candidate_low_auth_path.?);
        candidate_low_auth_path = null;
    }

    const attempt = try auto.maybeAutoSwitchWithUsageFetcher(gpa, codex_home, &reg, fetchCandidateUsageByAuthPath);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(!attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, low_account_id));
}

test "Scenario: Given repeated daemon candidate refresh attempts within cooldown when auto switching then candidate API refresh is rate-limited" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "low@example.com", .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "fresh@example.com", null, null);
    const low_account_id = try bdd.accountKeyForEmailAlloc(gpa, "low@example.com");
    defer gpa.free(low_account_id);
    try registry.setActiveAccountKey(gpa, &reg, low_account_id);

    const fresh_account_id = try bdd.accountKeyForEmailAlloc(gpa, "fresh@example.com");
    defer gpa.free(fresh_account_id);
    const fresh_auth = try bdd.authJsonWithEmailPlan(gpa, "fresh@example.com", "pro");
    defer gpa.free(fresh_auth);
    const fresh_path = try registry.accountAuthPath(gpa, codex_home, fresh_account_id);
    defer gpa.free(fresh_path);
    try fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });

    candidate_low_auth_path = try gpa.dupe(u8, fresh_path);
    defer {
        gpa.free(candidate_low_auth_path.?);
        candidate_low_auth_path = null;
    }

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const first_attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingCandidateUsageByAuthPathDetailed);
    const second_attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingCandidateUsageByAuthPathDetailed);

    try std.testing.expect(first_attempt.refreshed_candidates);
    try std.testing.expect(!first_attempt.switched);
    try std.testing.expect(!second_attempt.refreshed_candidates);
    try std.testing.expect(!second_attempt.switched);
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given switch-time candidate validation returns non-200 then that candidate is disqualified" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageHttp403);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(!attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, active_account_id));
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given switch-time candidate validation returns 200 without windows then that candidate is disqualified" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageNoWindow200);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(!attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, active_account_id));
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given a candidate is rejected by API validation then it stays rejected across the next daemon cycle" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const first_attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageHttp403);
    const second_attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageHttp403);

    try std.testing.expect(first_attempt.refreshed_candidates);
    try std.testing.expect(!first_attempt.switched);
    try std.testing.expect(!second_attempt.refreshed_candidates);
    try std.testing.expect(!second_attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, active_account_id));
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given switch-time candidate validation reports missing auth then that candidate is disqualified" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageMissingAuth);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(!attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, active_account_id));
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given switch-time candidate validation gets no response then the candidate remains eligible" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCandidateUsageUnavailable);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, candidate_account_id));
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);
}

test "Scenario: Given daemon api mode and an api-key candidate when auto switching then the candidate stays eligible without usage refresh" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 99.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 90.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "apikey@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "apikey@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "active@example.com", "pro");
    defer gpa.free(active_auth);
    const active_account_path = try registry.accountAuthPath(gpa, codex_home, active_account_id);
    defer gpa.free(active_account_path);
    const candidate_account_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_account_path);
    const active_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_path);

    try fs.cwd().writeFile(.{ .sub_path = active_account_path, .data = active_auth });
    try fs.cwd().writeFile(.{ .sub_path = candidate_account_path, .data = "{\"OPENAI_API_KEY\":\"sk-test\"}" });
    try fs.cwd().writeFile(.{ .sub_path = active_path, .data = active_auth });

    const candidate_idx = bdd.findAccountIndexByEmail(&reg, "apikey@example.com") orelse return error.TestExpectedEqual;
    reg.accounts.items[candidate_idx].auth_mode = .apikey;

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingCandidateUsageByAuthPathDetailed);
    try std.testing.expect(!attempt.refreshed_candidates);
    try std.testing.expect(attempt.switched);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, candidate_account_id));
    try std.testing.expectEqual(@as(usize, 0), candidate_api_fetch_count);

    const active_auth_data = try bdd.readFileAlloc(gpa, active_path);
    defer gpa.free(active_auth_data);
    try std.testing.expectEqualStrings("{\"OPENAI_API_KEY\":\"sk-test\"}", active_auth_data);
}

test "Scenario: Given healthy active usage when daemon runs then it performs only bounded candidate upkeep" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 10.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "candidate@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const candidate_account_id = try bdd.accountKeyForEmailAlloc(gpa, "candidate@example.com");
    defer gpa.free(candidate_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const candidate_auth = try bdd.authJsonWithEmailPlan(gpa, "candidate@example.com", "pro");
    defer gpa.free(candidate_auth);
    const candidate_path = try registry.accountAuthPath(gpa, codex_home, candidate_account_id);
    defer gpa.free(candidate_path);
    try fs.cwd().writeFile(.{ .sub_path = candidate_path, .data = candidate_auth });

    candidate_high_auth_path = try gpa.dupe(u8, candidate_path);
    defer {
        gpa.free(candidate_high_auth_path.?);
        candidate_high_auth_path = null;
    }

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingCandidateUsageByAuthPathDetailed);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(attempt.state_changed);
    try std.testing.expect(!attempt.switched);
    try std.testing.expectEqual(@as(usize, 1), candidate_api_fetch_count);

    const candidate_idx = bdd.findAccountIndexByEmail(&reg, "candidate@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[candidate_idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 12.0), reg.accounts.items[candidate_idx].last_usage.?.primary.?.used_percent);
}

test "Scenario: Given stale top candidates when daemon switches then it validates them in priority order instead of refreshing all candidates" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.auto_switch.enabled = true;
    reg.api.usage = true;

    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 96.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 70.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .pro,
    }, 100);
    try appendAccountWithUsage(gpa, &reg, "first@example.com", null, null);
    try appendAccountWithUsage(gpa, &reg, "second@example.com", null, null);
    try appendAccountWithUsage(gpa, &reg, "third@example.com", null, null);

    const active_account_id = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    const first_account_id = try bdd.accountKeyForEmailAlloc(gpa, "first@example.com");
    defer gpa.free(first_account_id);
    const second_account_id = try bdd.accountKeyForEmailAlloc(gpa, "second@example.com");
    defer gpa.free(second_account_id);
    const third_account_id = try bdd.accountKeyForEmailAlloc(gpa, "third@example.com");
    defer gpa.free(third_account_id);
    try registry.setActiveAccountKey(gpa, &reg, active_account_id);

    const first_auth = try bdd.authJsonWithEmailPlan(gpa, "first@example.com", "pro");
    defer gpa.free(first_auth);
    const second_auth = try bdd.authJsonWithEmailPlan(gpa, "second@example.com", "pro");
    defer gpa.free(second_auth);
    const third_auth = try bdd.authJsonWithEmailPlan(gpa, "third@example.com", "pro");
    defer gpa.free(third_auth);
    const first_path = try registry.accountAuthPath(gpa, codex_home, first_account_id);
    defer gpa.free(first_path);
    const second_path = try registry.accountAuthPath(gpa, codex_home, second_account_id);
    defer gpa.free(second_path);
    const third_path = try registry.accountAuthPath(gpa, codex_home, third_account_id);
    defer gpa.free(third_path);
    const active_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_path);
    try fs.cwd().writeFile(.{ .sub_path = first_path, .data = first_auth });
    try fs.cwd().writeFile(.{ .sub_path = second_path, .data = second_auth });
    try fs.cwd().writeFile(.{ .sub_path = third_path, .data = third_auth });
    try fs.cwd().writeFile(.{ .sub_path = active_path, .data = first_auth });

    candidate_low_auth_path = try gpa.dupe(u8, first_path);
    candidate_high_auth_path = try gpa.dupe(u8, second_path);
    candidate_reject_auth_path = try gpa.dupe(u8, third_path);
    defer {
        gpa.free(candidate_low_auth_path.?);
        candidate_low_auth_path = null;
        gpa.free(candidate_high_auth_path.?);
        candidate_high_auth_path = null;
        gpa.free(candidate_reject_auth_path.?);
        candidate_reject_auth_path = null;
    }

    candidate_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    const attempt = try auto.maybeAutoSwitchForDaemonWithUsageFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingCandidateUsageByAuthPathDetailed);
    try std.testing.expect(attempt.refreshed_candidates);
    try std.testing.expect(attempt.switched);
    try std.testing.expectEqual(@as(usize, 3), candidate_api_fetch_count);
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, second_account_id));
}

test "Scenario: Given linux service unit when rendering then it keeps a persistent daemon watcher alive" {
    const gpa = std.testing.allocator;
    const unit = try auto.linuxUnitText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Description=codex-auth auto-switch watcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Type=simple") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Restart=always") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"CODEX_AUTH_VERSION=") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"CODEX_HOME=/tmp/custom-codex-home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=\"/tmp/codex-auth\" daemon --watch") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "[Install]") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WantedBy=default.target") != null);
}

test "Scenario: Given a zig build run executable path when resolving the managed service binary then it prefers zig-out" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("zig-out/bin");
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/bin/codex-auth", .data = "" });

    const path = try auto.managedServiceSelfExePathFromDir(
        gpa,
        tmp.dir,
        "/tmp/codex-auth/.zig-cache/o/abcd1234/codex-auth",
    );
    defer gpa.free(path);

    const expected = try tmp.dir.realpathAlloc(gpa, "zig-out/bin/codex-auth");
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "Scenario: Given a stable executable path when resolving the managed service binary then it keeps the original path" {
    const gpa = std.testing.allocator;
    const path = try auto.managedServiceSelfExePath(gpa, "/usr/local/bin/codex-auth");
    defer gpa.free(path);

    try std.testing.expectEqualStrings("/usr/local/bin/codex-auth", path);
}

test "Scenario: Given mac plist when rendering then it includes version metadata and daemon args" {
    const gpa = std.testing.allocator;
    const plist = try auto.macPlistText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(plist);

    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CODEX_AUTH_VERSION</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CODEX_HOME</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/tmp/custom-codex-home</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>daemon</string>") != null);
}

test "Scenario: Given windows task action when rendering then it launches the helper directly without cmd" {
    const gpa = std.testing.allocator;
    const action = try auto.windowsTaskAction(gpa, "C:\\Program Files\\codex-auth\\codex-auth-auto.exe", "C:\\Users\\demo\\Codex Home\\");
    defer gpa.free(action);

    try std.testing.expect(std.mem.indexOf(u8, action, "cmd.exe /D /C") == null);
    try std.testing.expect(std.mem.indexOf(u8, action, "\"C:\\Program Files\\codex-auth\\codex-auth-auto.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "--service-version ") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "--codex-home \"C:\\Users\\demo\\Codex Home\\\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "powershell.exe") == null);
    try std.testing.expect(action.len < 262);
}

test "Scenario: Given windows task register script when rendering then it configures restart-on-failure" {
    const gpa = std.testing.allocator;
    const script = try auto.windowsRegisterTaskScript(gpa, "C:\\Program Files\\codex-auth\\codex-auth-auto.exe", "C:\\Users\\demo\\Codex Home\\");
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "New-ScheduledTaskAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--codex-home \"C:\\Users\\demo\\Codex Home\\\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "New-ScheduledTaskTrigger -AtLogOn") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "-ExecutionTimeLimit (New-TimeSpan -Seconds 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Register-ScheduledTask -TaskName 'CodexAuthAutoSwitch'") != null);
}

test "Scenario: Given windows task match script when rendering then it validates both action and the logon trigger" {
    const gpa = std.testing.allocator;
    const script = try auto.windowsTaskMatchScript(gpa);
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "Get-ScheduledTask -TaskName 'CodexAuthAutoSwitch' -ErrorAction SilentlyContinue") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Export-ScheduledTask -TaskName 'CodexAuthAutoSwitch'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "RestartOnFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ExecutionTimeLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "LocalName") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$action.Execute + $args + '|TRIGGER:' + $triggerKind + '|RESTART:' + $restartCount + ',' + $restartInterval + '|LIMIT:' + $executionLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "|TRIGGER:") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "|RESTART:") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "|LIMIT:") != null);
}

test "Scenario: Given auto-switch disabled when reconciling managed service then it stays off" {
    try std.testing.expect(!auto.shouldEnsureManagedService(false, .stopped, false));
    try std.testing.expect(!auto.shouldEnsureManagedService(false, .running, true));
}

test "Scenario: Given auto-switch enabled with stopped or stale service when reconciling then it is refreshed" {
    try std.testing.expect(auto.shouldEnsureManagedService(true, .stopped, true));
    try std.testing.expect(auto.shouldEnsureManagedService(true, .running, false));
    try std.testing.expect(!auto.shouldEnsureManagedService(true, .running, true));
}

test "Scenario: Given partial service install failure when enabling auto-switch then registry and artifacts roll back" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    try std.testing.expectError(
        error.TestInstallFailed,
        auto.enableWithServiceHooksAndPreflight(
            gpa,
            codex_home,
            "/tmp/codex-auth",
            installServiceWithPartialArtifact,
            uninstallPartialServiceArtifact,
            preflightSuccess,
        ),
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(!loaded.auto_switch.enabled);

    const artifact_path = try partialServiceArtifactPath(gpa, codex_home);
    defer gpa.free(artifact_path);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(artifact_path, .{}));
}

test "Scenario: Given preflight failure when enabling auto-switch then registry is unchanged and installer is skipped" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try registry.ensureAccountsDir(gpa, codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    try std.testing.expectError(
        error.TestPreflightFailed,
        auto.enableWithServiceHooksAndPreflight(
            gpa,
            codex_home,
            "/tmp/codex-auth",
            installServiceWithPartialArtifact,
            uninstallPartialServiceArtifact,
            preflightFailure,
        ),
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expect(!loaded.auto_switch.enabled);

    const artifact_path = try partialServiceArtifactPath(gpa, codex_home);
    defer gpa.free(artifact_path);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(artifact_path, .{}));
}

test "Scenario: Given supported and unsupported OS tags when checking service support then only managed-service platforms reconcile" {
    try std.testing.expect(auto.supportsManagedServiceOnPlatform(.linux));
    try std.testing.expect(auto.supportsManagedServiceOnPlatform(.macos));
    try std.testing.expect(auto.supportsManagedServiceOnPlatform(.windows));
    try std.testing.expect(!auto.supportsManagedServiceOnPlatform(.freebsd));
}

test "Scenario: Given automatic switch when writing daemon log then it records source and destination emails" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "from@example.com", "work", null);
    try bdd.appendAccount(gpa, &reg, "to@example.com", "personal", null);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try auto.writeAutoSwitchLogLine(&aw.writer, &reg.accounts.items[0], &reg.accounts.items[1]);

    const output = aw.written();
    try std.testing.expect(std.mem.eql(u8, output, "[switch] from@example.com -> to@example.com\n"));
}

test "Scenario: Given an absolute managed unit path when deleting it then the file is removed" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "codex-auth-autoswitch.timer", .data = "[Timer]\n" });
    const timer_path = try tmp.dir.realpathAlloc(gpa, "codex-auth-autoswitch.timer");
    defer gpa.free(timer_path);

    auto.deleteAbsoluteFileIfExists(timer_path);

    try std.testing.expectError(error.FileNotFound, fs.openFileAbsolute(timer_path, .{}));
}

test "Scenario: Given windows delete task script when rendering then missing tasks are treated as success" {
    const gpa = std.testing.allocator;
    const script = try auto.windowsDeleteTaskScript(gpa);
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "Get-ScheduledTask -TaskName 'CodexAuthAutoSwitch' -ErrorAction SilentlyContinue") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "if ($null -eq $task) { exit 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Unregister-ScheduledTask -TaskName 'CodexAuthAutoSwitch' -Confirm:$false") != null);
}

test "Scenario: Given windows task state output when parsing then localized text is no longer required" {
    try std.testing.expect(auto.parseWindowsTaskStateOutput("4\r\n") == .running);
    try std.testing.expect(auto.parseWindowsTaskStateOutput("3\r\n") == .stopped);
    try std.testing.expect(auto.parseWindowsTaskStateOutput("2\r\n") == .stopped);
    try std.testing.expect(auto.parseWindowsTaskStateOutput("1\r\n") == .stopped);
    try std.testing.expect(auto.parseWindowsTaskStateOutput("garbled\r\n") == .unknown);
}

test "Scenario: Given status when rendering then auto and usage api settings are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try auto.writeStatus(&aw.writer, .{
        .enabled = true,
        .runtime = .running,
        .threshold_5h_percent = 12,
        .threshold_weekly_percent = 8,
        .api_usage_enabled = false,
        .api_account_enabled = false,
    });

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "auto-switch: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service: running") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thresholds: 5h<12%, weekly<8%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "usage: local") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "account: disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Warning: Usage refresh is currently using the ChatGPT usage API") == null);
}

test "Scenario: Given api usage mode when rendering status body then risk warning stays off stdout" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try auto.writeStatus(&aw.writer, .{
        .enabled = true,
        .runtime = .running,
        .threshold_5h_percent = 12,
        .threshold_weekly_percent = 8,
        .api_usage_enabled = true,
        .api_account_enabled = true,
    });

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "usage: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "account: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Warning: Usage refresh is currently using the ChatGPT usage API") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`codex-auth config api disable`") == null);
}

test "Scenario: Given missing sessions dir when refreshing active usage then it is skipped without error" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(!(try auto.refreshActiveUsage(gpa, codex_home, &reg)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage == null);
}

test "Scenario: Given local-only mode when refreshing usage then api fetcher is never used" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(!(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiError)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage == null);
}

test "Scenario: Given local-only daemon mode and newest null-limits event when refreshing usage then it keeps the last usable local snapshot" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = false;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    reg.active_account_activated_at_ms = 0;

    const usable_then_null =
        "{\"timestamp\":\"2025-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}\n" ++
        "{\"timestamp\":\"2025-01-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = usable_then_null });

    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchApiError));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 55.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
}

test "Scenario: Given api-backed daemon mode and newest null-limits event with earlier usable local data when api is unavailable then it still applies the local snapshot" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    reg.active_account_activated_at_ms = 0;

    const usable_then_null =
        "{\"timestamp\":\"2025-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":55.0,\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}\n" ++
        "{\"timestamp\":\"2025-01-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n";
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = usable_then_null });

    daemon_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingApiError));
    try std.testing.expectEqual(@as(usize, 0), daemon_api_fetch_count);

    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 55.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expect(reg.accounts.items[idx].last_local_rollout != null);
    try std.testing.expectEqual(@as(i64, 1735689600000), reg.accounts.items[idx].last_local_rollout.?.event_timestamp_ms);
}

test "Scenario: Given api usage for active account when refreshing usage then it updates without rollout files" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try std.testing.expect(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiSnapshot));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 15.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(registry.PlanType.pro, reg.accounts.items[idx].last_usage.?.plan_type.?);
    try std.testing.expect(reg.accounts.items[idx].last_usage_at != null);
}

test "Scenario: Given unchanged api usage when refreshing usage then rollout fallback is skipped" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try appendAccountWithUsage(gpa, &reg, "active@example.com", apiSnapshot(), 777);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });

    try std.testing.expect(!(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiSnapshot)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f64, 15.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 777), reg.accounts.items[idx].last_usage_at.?);
}

test "Scenario: Given api-backed switch with stale rollout when api later fails then the stale rollout is not assigned to the new active account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);
    const account_id_a = try bdd.accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    try registry.setActiveAccountKey(gpa, &reg, account_id_a);
    reg.active_account_activated_at_ms = 0;
    reg.active_account_activated_at_ms = 0;

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });
    try std.testing.expect(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiSnapshot));

    const account_id_b = try bdd.accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    try registry.setActiveAccountKey(gpa, &reg, account_id_b);

    try std.testing.expect(!(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiError)));
    const b_idx = bdd.findAccountIndexByEmail(&reg, "b@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[b_idx].last_usage == null);
}

test "Scenario: Given unchanged rollout after switching accounts when refreshing usage then it is not reassigned to the new active account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = false;
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);
    const account_id_a = try bdd.accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    try registry.setActiveAccountKey(gpa, &reg, account_id_a);
    reg.active_account_activated_at_ms = 0;

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });

    try std.testing.expect(try auto.refreshActiveUsage(gpa, codex_home, &reg));
    const a_idx = bdd.findAccountIndexByEmail(&reg, "a@example.com") orelse return error.TestExpectedEqual;
    const b_idx = bdd.findAccountIndexByEmail(&reg, "b@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[a_idx].last_usage != null);

    const account_id_b = try bdd.accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    try registry.setActiveAccountKey(gpa, &reg, account_id_b);
    reg.active_account_activated_at_ms = 1735689600001;
    reg.active_account_activated_at_ms = 1735689630000;
    try std.testing.expect(!(try auto.refreshActiveUsage(gpa, codex_home, &reg)));
    try std.testing.expect(reg.accounts.items[b_idx].last_usage == null);
}

test "Scenario: Given new rollout event in the same file after switching accounts when refreshing usage then it is assigned to the new active account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = false;
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);
    const account_id_a = try bdd.accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    try registry.setActiveAccountKey(gpa, &reg, account_id_a);
    reg.active_account_activated_at_ms = 0;

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });
    try std.testing.expect(try auto.refreshActiveUsage(gpa, codex_home, &reg));

    const account_id_b = try bdd.accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    try registry.setActiveAccountKey(gpa, &reg, account_id_b);
    reg.active_account_activated_at_ms = 1735689630000;

    const next_rollout_line = "{" ++
        "\"timestamp\":\"2025-01-01T00:01:00Z\"," ++
        "\"type\":\"event_msg\"," ++
        "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":48.0,\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":12.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}";
    try tmp.dir.writeFile(.{
        .sub_path = "sessions/run-1/rollout-a.jsonl",
        .data = rollout_line ++ "\n" ++ next_rollout_line ++ "\n",
    });

    try std.testing.expect(try auto.refreshActiveUsage(gpa, codex_home, &reg));
    const b_idx = bdd.findAccountIndexByEmail(&reg, "b@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[b_idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 48.0), reg.accounts.items[b_idx].last_usage.?.primary.?.used_percent);
}

test "Scenario: Given API-enabled mode and API failure when refreshing usage then local usage stays untouched and local rollout state is unchanged" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });

    try std.testing.expect(!(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiError)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage == null);
    try std.testing.expect(reg.accounts.items[idx].last_local_rollout == null);
}

test "Scenario: Given daemon sees a null-rate-limits rollout then it falls back to the API without overwriting local rollout state" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = null_rate_limits_rollout_line ++ "\n" });

    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchApiSnapshot));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 15.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expect(reg.accounts.items[idx].last_local_rollout == null);
}

test "Scenario: Given daemon sees an empty-rate-limits rollout then it also falls back to the API" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = empty_rate_limits_rollout_line ++ "\n" });

    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchApiSnapshot));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 15.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expect(reg.accounts.items[idx].last_local_rollout == null);
}

test "Scenario: Given repeated bad rollout events within the daemon cooldown then API fallback is rate-limited" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "active@example.com", "", null);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = null_rate_limits_rollout_line ++ "\n" });

    daemon_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingApiSnapshot));
    try std.testing.expect(!(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingApiSnapshot)));
    try std.testing.expectEqual(@as(usize, 1), daemon_api_fetch_count);
}

test "Scenario: Given the active daemon account changes during API cooldown then the new account refreshes immediately" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);

    const account_id_a = try bdd.accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    const account_id_b = try bdd.accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);

    try registry.setActiveAccountKey(gpa, &reg, account_id_a);

    daemon_api_fetch_count = 0;
    var refresh_state = auto.DaemonRefreshState{};
    defer refresh_state.deinit(gpa);

    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingApiSnapshot));
    try std.testing.expectEqual(@as(usize, 1), daemon_api_fetch_count);

    try registry.setActiveAccountKey(gpa, &reg, account_id_b);
    try std.testing.expect(try auto.refreshActiveUsageForDaemonWithApiFetcher(gpa, codex_home, &reg, &refresh_state, fetchCountingApiSnapshot));
    try std.testing.expectEqual(@as(usize, 2), daemon_api_fetch_count);
}

test "Scenario: Given api failure when returning to local refresh after switching accounts then the pre-switch rollout is not assigned to the new active account" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    reg.api.usage = true;
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);
    const account_id_a = try bdd.accountKeyForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    try registry.setActiveAccountKey(gpa, &reg, account_id_a);

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });

    try std.testing.expect(!(try auto.refreshActiveUsageWithApiFetcher(gpa, codex_home, &reg, fetchApiError)));

    const account_id_b = try bdd.accountKeyForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    try registry.setActiveAccountKey(gpa, &reg, account_id_b);
    reg.api.usage = false;

    try std.testing.expect(!(try auto.refreshActiveUsage(gpa, codex_home, &reg)));
    const b_idx = bdd.findAccountIndexByEmail(&reg, "b@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[b_idx].last_usage == null);
}

test "Scenario: Given latest rollout file without usable rate limits when refreshing usage then stored usage is preserved" {
    const gpa = std.testing.allocator;
    var tmp = fs.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try appendAccountWithUsage(gpa, &reg, "active@example.com", .{
        .primary = .{ .used_percent = 41.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 12.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = .team,
    }, 777);
    const active_account_key = try bdd.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = "{\"timestamp\":\"2025-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-b.jsonl", .data = "{\"timestamp\":\"2025-01-01T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-c.jsonl", .data = "{\"timestamp\":\"2025-01-01T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-d.jsonl", .data = rollout_line ++ "\n" });

    const base_time = @as(i128, time_compat.nanoTimestamp());
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-d.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time, base_time);
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-c.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + time_compat.ns_per_s, base_time + time_compat.ns_per_s);
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-b.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (2 * time_compat.ns_per_s), base_time + (2 * time_compat.ns_per_s));
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-a.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (3 * time_compat.ns_per_s), base_time + (3 * time_compat.ns_per_s));
    }

    try std.testing.expect(!(try auto.refreshActiveUsage(gpa, codex_home, &reg)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 41.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 777), reg.accounts.items[idx].last_usage_at.?);
}
