const std = @import("std");
const account_api = @import("../account_api.zig");
const auth_mod = @import("../auth.zig");
const display_rows = @import("../display_rows.zig");
const main_mod = @import("../main.zig");
const registry = @import("../registry.zig");
const usage_api = @import("../usage_api.zig");
const bdd = @import("bdd_helpers.zig");

const shared_user_id = "user-ESYgcy2QkOGZc0NoxSlFCeVT";
const primary_account_id = "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";
const secondary_account_id = "518a44d9-ba75-4bad-87e5-ae9377042960";
const tertiary_account_id = "a4021fa5-998b-4774-989f-784fa69c367b";
const primary_record_key = shared_user_id ++ "::" ++ primary_account_id;
const secondary_record_key = shared_user_id ++ "::" ++ secondary_account_id;
const tertiary_record_key = shared_user_id ++ "::" ++ tertiary_account_id;
const standalone_team_user_id = "user-q2Lm6Nx8Vc4Rb7Ty1Hp9JkDs";
const standalone_team_account_id = "29a9c0cb-e840-45ec-97bf-d6c5f7e0f55b";
const standalone_team_record_key = standalone_team_user_id ++ "::" ++ standalone_team_account_id;

var mock_account_name_fetch_count: usize = 0;
var mutate_registry_during_account_fetch = false;
var mutate_registry_codex_home: ?[]const u8 = null;
var expected_mock_account_name_fetch_account_id: ?[]const u8 = null;

fn resetMockAccountNameFetcher() void {
    mock_account_name_fetch_count = 0;
    mutate_registry_during_account_fetch = false;
    mutate_registry_codex_home = null;
    expected_mock_account_name_fetch_account_id = null;
}

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn writeSnapshot(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8, plan: []const u8) !void {
    const account_key = try bdd.accountKeyForEmailAlloc(allocator, email);
    defer allocator.free(account_key);
    const snapshot_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(snapshot_path);
    const auth_json = try bdd.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = snapshot_path, .data = auth_json });
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

fn authJsonWithIdsAndLastRefresh(
    allocator: std.mem.Allocator,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
    access_token: []const u8,
    last_refresh: []const u8,
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
        "{{\"tokens\":{{\"access_token\":\"{s}\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}},\"last_refresh\":\"{s}\"}}",
        .{ access_token, chatgpt_account_id, jwt, last_refresh },
    );
}

fn parseAuthInfoWithIds(
    allocator: std.mem.Allocator,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) !auth_mod.AuthInfo {
    const auth_json = try authJsonWithIds(allocator, email, plan, chatgpt_user_id, chatgpt_account_id);
    defer allocator.free(auth_json);
    return try auth_mod.parseAuthInfoData(allocator, auth_json);
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
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
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

    try registry.ensureAccountsDir(allocator, codex_home);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const auth_json = try authJsonWithIds(allocator, email, plan, chatgpt_user_id, chatgpt_account_id);
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn writeAccountSnapshotWithIdsAndLastRefresh(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    email: []const u8,
    plan: []const u8,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
    access_token: []const u8,
    last_refresh: []const u8,
) !void {
    const account_key = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
    defer allocator.free(account_key);

    try registry.ensureAccountsDir(allocator, codex_home);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const auth_json = try authJsonWithIdsAndLastRefresh(
        allocator,
        email,
        plan,
        chatgpt_user_id,
        chatgpt_account_id,
        access_token,
        last_refresh,
    );
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = auth_path, .data = auth_json });
}

fn mockAccountNameFetcher(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    _ = access_token;
    if (expected_mock_account_name_fetch_account_id) |expected_account_id| {
        if (!std.mem.eql(u8, account_id, expected_account_id)) return error.TestUnexpectedAccountId;
    }
    mock_account_name_fetch_count += 1;

    const entries = try allocator.alloc(account_api.AccountEntry, 2);
    errdefer allocator.free(entries);

    entries[0] = .{
        .account_id = try allocator.dupe(u8, primary_account_id),
        .account_name = try allocator.dupe(u8, "Primary Workspace"),
    };
    errdefer {
        entries[0].deinit(allocator);
    }
    entries[1] = .{
        .account_id = try allocator.dupe(u8, secondary_account_id),
        .account_name = try allocator.dupe(u8, "Backup Workspace"),
    };
    errdefer {
        entries[1].deinit(allocator);
    }

    return .{
        .entries = entries,
        .status_code = 200,
    };
}

fn mockAccountNameFetcherWithRegistryMutation(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    if (mutate_registry_during_account_fetch) {
        const codex_home = mutate_registry_codex_home orelse return error.TestExpectedEqual;
        var reg = try registry.loadRegistry(allocator, codex_home);
        defer reg.deinit(allocator);
        reg.api.usage = false;
        reg.api.account = false;
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    return try mockAccountNameFetcher(allocator, access_token, account_id);
}

fn mockAccountNameFetcherRequiringFreshToken(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: []const u8,
) !account_api.FetchResult {
    if (!std.mem.eql(u8, access_token, "fresh-token")) return error.Unauthorized;
    return try mockAccountNameFetcher(allocator, access_token, account_id);
}

test "Scenario: Given alias, email, and account name queries when finding matching accounts then all matching strategies work" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-A1B2C3D4E5F6::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "team-work", .team);
    try appendAccount(gpa, &reg, "user-Z9Y8X7W6V5U4::518a44d9-ba75-4bad-87e5-ae9377042960", "other@example.com", "", .plus);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Ops Workspace");

    var alias_matches = try main_mod.findMatchingAccounts(gpa, &reg, "team-work");
    defer alias_matches.deinit(gpa);
    try std.testing.expect(alias_matches.items.len == 1);
    try std.testing.expect(alias_matches.items[0] == 0);

    var email_matches = try main_mod.findMatchingAccounts(gpa, &reg, "other@example");
    defer email_matches.deinit(gpa);
    try std.testing.expect(email_matches.items.len == 1);
    try std.testing.expect(email_matches.items[0] == 1);

    var name_matches = try main_mod.findMatchingAccounts(gpa, &reg, "workspace");
    defer name_matches.deinit(gpa);
    try std.testing.expect(name_matches.items.len == 1);
    try std.testing.expect(name_matches.items[0] == 1);
}

test "Scenario: Given account_id query when finding matching accounts then it is ignored for switch lookup" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-A1B2C3D4E5F6::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);

    var matches = try main_mod.findMatchingAccounts(gpa, &reg, "67fe2bbb");
    defer matches.deinit(gpa);
    try std.testing.expect(matches.items.len == 0);
}

test "Scenario: Given foreground commands when checking reconcile policy then config commands self-heal services but status does not" {
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .list = .{} }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .auto_switch = .{ .action = .enable } } }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .auto_switch = .{ .configure = .{
        .threshold_5h_percent = 12,
        .threshold_weekly_percent = null,
    } } } }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .api = .enable } }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .help = .top_level }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .status = {} }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .version = {} }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .daemon = .{ .mode = .once } }));
}

test "Scenario: Given foreground usage refresh targets when checking refresh policy then list and switch refresh but remove does not" {
    try std.testing.expect(main_mod.shouldRefreshForegroundUsage(.list));
    try std.testing.expect(main_mod.shouldRefreshForegroundUsage(.switch_account));
    try std.testing.expect(!main_mod.shouldRefreshForegroundUsage(.remove_account));
}

test "Scenario: Given api usage refresh for list and switch when refreshing foreground usage then all accounts are updated with status overlays" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const TestUsageFetcher = struct {
        fn snapshot(plan: registry.PlanType, used_5h: f64, used_weekly: f64) registry.RateLimitSnapshot {
            return .{
                .primary = .{
                    .used_percent = used_5h,
                    .window_minutes = 300,
                    .resets_at = 1773491460,
                },
                .secondary = .{
                    .used_percent = used_weekly,
                    .window_minutes = 10080,
                    .resets_at = 1773749620,
                },
                .credits = null,
                .plan_type = plan,
            };
        }

        fn fetch(allocator: std.mem.Allocator, auth_path: []const u8) !usage_api.UsageFetchResult {
            var info = try auth_mod.parseAuthInfo(allocator, auth_path);
            defer info.deinit(allocator);

            const account_id = info.chatgpt_account_id orelse return .{
                .snapshot = null,
                .status_code = null,
                .missing_auth = true,
            };

            if (std.mem.eql(u8, account_id, primary_account_id)) {
                return .{
                    .snapshot = snapshot(.team, 18, 39),
                    .status_code = 200,
                };
            }
            if (std.mem.eql(u8, account_id, secondary_account_id)) {
                return .{
                    .snapshot = null,
                    .status_code = 403,
                };
            }
            if (std.mem.eql(u8, account_id, tertiary_account_id)) {
                return .{
                    .snapshot = snapshot(.plus, 30, 55),
                    .status_code = 200,
                };
            }
            return .{
                .snapshot = null,
                .status_code = 404,
            };
        }
    };

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, tertiary_record_key, "user@example.com", "", .plus);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);

    reg.accounts.items[2].last_usage = TestUsageFetcher.snapshot(.plus, 30, 55);
    reg.accounts.items[2].last_usage_at = 10;

    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);
    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, secondary_account_id);
    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "plus", shared_user_id, tertiary_account_id);

    var state = try main_mod.refreshForegroundUsageForDisplayWithApiFetcher(
        gpa,
        codex_home,
        &reg,
        TestUsageFetcher.fetch,
    );
    defer state.deinit(gpa);

    try std.testing.expect(!state.local_only_mode);
    try std.testing.expectEqual(@as(usize, 3), state.attempted);
    try std.testing.expectEqual(@as(usize, 1), state.updated);
    try std.testing.expectEqual(@as(usize, 1), state.failed);
    try std.testing.expectEqual(@as(usize, 1), state.unchanged);

    try std.testing.expect(state.usage_overrides[0] == null);
    try std.testing.expectEqualStrings("403", state.usage_overrides[1].?);
    try std.testing.expect(state.usage_overrides[2] == null);

    try std.testing.expect(state.outcomes[0].updated);
    try std.testing.expectEqual(@as(?u16, 403), state.outcomes[1].status_code);
    try std.testing.expect(state.outcomes[2].unchanged);

    try std.testing.expectEqual(@as(?registry.PlanType, .team), reg.accounts.items[0].last_usage.?.plan_type);
    try std.testing.expectEqual(@as(f64, 18), reg.accounts.items[0].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(f64, 55), reg.accounts.items[2].last_usage.?.secondary.?.used_percent);
}

test "Scenario: Given thread pool init failure when refreshing foreground usage then it falls back to serial refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const TestUsageFetcher = struct {
        fn snapshot(plan: registry.PlanType, used_5h: f64, used_weekly: f64) registry.RateLimitSnapshot {
            return .{
                .primary = .{
                    .used_percent = used_5h,
                    .window_minutes = 300,
                    .resets_at = 1773491460,
                },
                .secondary = .{
                    .used_percent = used_weekly,
                    .window_minutes = 10080,
                    .resets_at = 1773749620,
                },
                .credits = null,
                .plan_type = plan,
            };
        }

        fn fetch(allocator: std.mem.Allocator, auth_path: []const u8) !usage_api.UsageFetchResult {
            var info = try auth_mod.parseAuthInfo(allocator, auth_path);
            defer info.deinit(allocator);

            const account_id = info.chatgpt_account_id orelse return .{
                .snapshot = null,
                .status_code = null,
                .missing_auth = true,
            };

            if (std.mem.eql(u8, account_id, primary_account_id)) {
                return .{
                    .snapshot = snapshot(.team, 22, 41),
                    .status_code = 200,
                };
            }
            return .{
                .snapshot = null,
                .status_code = 403,
            };
        }

        fn failPoolInit(
            pool: *std.Thread.Pool,
            allocator: std.mem.Allocator,
            n_jobs: usize,
        ) !void {
            _ = pool;
            _ = allocator;
            _ = n_jobs;
            return error.ThreadQuotaExceeded;
        }
    };

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);

    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);
    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, secondary_account_id);

    var state = try main_mod.refreshForegroundUsageForDisplayWithApiFetcherWithPoolInit(
        gpa,
        codex_home,
        &reg,
        TestUsageFetcher.fetch,
        TestUsageFetcher.failPoolInit,
    );
    defer state.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), state.attempted);
    try std.testing.expectEqual(@as(usize, 1), state.updated);
    try std.testing.expectEqual(@as(usize, 1), state.failed);
    try std.testing.expectEqualStrings("403", state.usage_overrides[1].?);
    try std.testing.expectEqual(@as(f64, 22), reg.accounts.items[0].last_usage.?.primary.?.used_percent);
}

test "Scenario: Given debug usage refresh when listing then request and response details stream in refresh order" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    const TestUsageFetcher = struct {
        fn snapshot(plan: registry.PlanType, used_5h: f64, used_weekly: f64) registry.RateLimitSnapshot {
            return .{
                .primary = .{
                    .used_percent = used_5h,
                    .window_minutes = 300,
                    .resets_at = 4773491460,
                },
                .secondary = .{
                    .used_percent = used_weekly,
                    .window_minutes = 10080,
                    .resets_at = 4773749620,
                },
                .credits = null,
                .plan_type = plan,
            };
        }

        fn fetch(allocator: std.mem.Allocator, auth_path: []const u8) !usage_api.UsageFetchResult {
            var info = try auth_mod.parseAuthInfo(allocator, auth_path);
            defer info.deinit(allocator);

            const account_id = info.chatgpt_account_id orelse return .{
                .snapshot = null,
                .status_code = null,
                .missing_auth = true,
            };

            if (std.mem.eql(u8, account_id, primary_account_id)) {
                return .{
                    .snapshot = snapshot(.team, 18, 39),
                    .status_code = 200,
                };
            }
            if (std.mem.eql(u8, account_id, secondary_account_id)) {
                return .{
                    .snapshot = null,
                    .status_code = 403,
                };
            }
            return .{
                .snapshot = null,
                .status_code = 404,
            };
        }

        fn failPoolInit(
            pool: *std.Thread.Pool,
            allocator: std.mem.Allocator,
            n_jobs: usize,
        ) !void {
            _ = pool;
            _ = allocator;
            _ = n_jobs;
            return error.ThreadQuotaExceeded;
        }
    };

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "alpha@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "beta@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);

    try writeAccountSnapshotWithIds(gpa, codex_home, "alpha@example.com", "team", shared_user_id, primary_account_id);
    try writeAccountSnapshotWithIds(gpa, codex_home, "beta@example.com", "team", shared_user_id, secondary_account_id);

    var debug_output: std.Io.Writer.Allocating = .init(gpa);
    defer debug_output.deinit();
    var debug_logger = main_mod.ForegroundUsageDebugLogger.init(&debug_output.writer);

    var state = try main_mod.refreshForegroundUsageForDisplayWithApiFetcherWithPoolInitAndDebug(
        gpa,
        codex_home,
        &reg,
        TestUsageFetcher.fetch,
        TestUsageFetcher.failPoolInit,
        &debug_logger,
    );
    defer state.deinit(gpa);

    const debug_text = debug_output.written();
    const start_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] usage refresh start: accounts=2 concurrency=2 timeout_ms=5000 child_timeout_ms=7000 endpoint=https://chatgpt.com/backend-api/wham/usage node=",
    ) orelse return error.TestExpectedEqual;
    const request_primary_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] request usage: alpha@example.com account_id=67fe2bbb-0de6-49a4-b2b3-d1df366d1faf\n",
    ) orelse return error.TestExpectedEqual;
    const response_primary_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] response usage: alpha@example.com status=200 result=usage-windows\n",
    ) orelse return error.TestExpectedEqual;
    const updated_primary_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] updated usage: alpha@example.com ",
    ) orelse return error.TestExpectedEqual;
    const request_secondary_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] request usage: beta@example.com account_id=518a44d9-ba75-4bad-87e5-ae9377042960\n",
    ) orelse return error.TestExpectedEqual;
    const response_secondary_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] response usage: beta@example.com status=403 result=http-response\n",
    ) orelse return error.TestExpectedEqual;
    const done_idx = std.mem.indexOf(
        u8,
        debug_text,
        "[debug] usage refresh done: attempted=2 updated=1 failed=1 unchanged=0\n",
    ) orelse return error.TestExpectedEqual;

    try std.testing.expect(start_idx < request_primary_idx);
    try std.testing.expect(request_primary_idx < response_primary_idx);
    try std.testing.expect(response_primary_idx < updated_primary_idx);
    try std.testing.expect(updated_primary_idx < request_secondary_idx);
    try std.testing.expect(request_secondary_idx < response_secondary_idx);
    try std.testing.expect(response_secondary_idx < done_idx);
}

test "Scenario: Given list with missing team names when running foreground account-name refresh then it waits and saves the updated names" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = primary_account_id;
    try main_mod.maybeRefreshForegroundAccountNames(gpa, codex_home, &reg, .list, mockAccountNameFetcher);

    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expectEqualStrings("Primary Workspace", reg.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", reg.accounts.items[1].account_name.?);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[1].account_name.?);
}

test "Scenario: Given switch with missing team names when running foreground account-name refresh then it waits and saves the updated names" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = primary_account_id;
    try main_mod.maybeRefreshForegroundAccountNames(gpa, codex_home, &reg, .switch_account, mockAccountNameFetcher);

    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expectEqualStrings("Primary Workspace", reg.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", reg.accounts.items[1].account_name.?);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings("Primary Workspace", loaded.accounts.items[0].account_name.?);
    try std.testing.expectEqualStrings("Backup Workspace", loaded.accounts.items[1].account_name.?);
}

test "Scenario: Given team name fetch candidates when checking grouped-account policy then only ambiguous team users qualify" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "same-user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "same-user@example.com", "", .free);
    try appendAccount(gpa, &reg, standalone_team_record_key, "solo-team@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-plus-only::acct-plus-a", "plus-only@example.com", "", .plus);
    try appendAccount(gpa, &reg, "user-plus-only::acct-plus-b", "plus-only-alt@example.com", "", .plus);

    try std.testing.expect(registry.shouldFetchTeamAccountNamesForUser(&reg, shared_user_id));
    try std.testing.expect(!registry.shouldFetchTeamAccountNamesForUser(&reg, standalone_team_user_id));
    try std.testing.expect(!registry.shouldFetchTeamAccountNamesForUser(&reg, "user-plus-only"));
}

test "Scenario: Given a standalone team account when building display rows and refreshing names then it keeps the email label and skips requests" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, standalone_team_record_key, "solo-team@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, standalone_team_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "solo-team@example.com", "team", standalone_team_user_id, standalone_team_account_id);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "solo-team@example.com"));
    try std.testing.expect(!registry.shouldFetchTeamAccountNamesForUser(&reg, standalone_team_user_id));

    var info = try parseAuthInfoWithIds(gpa, "solo-team@example.com", "team", standalone_team_user_id, standalone_team_account_id);
    defer info.deinit(gpa);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterLogin(gpa, &reg, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterImport(gpa, &reg, false, .single_file, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterSwitch(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
    try std.testing.expect(reg.accounts.items[0].account_name == null);
}

test "Scenario: Given grouped team accounts with account api disabled when refreshing names then every entry point skips requests" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    reg.api.account = false;
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    var info = try parseAuthInfoWithIds(gpa, "user@example.com", "team", shared_user_id, primary_account_id);
    defer info.deinit(gpa);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterLogin(gpa, &reg, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterImport(gpa, &reg, false, .single_file, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterSwitch(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
}

test "Scenario: Given grouped team accounts with account api disabled when checking switch background refresh then it is skipped" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);
    reg.api.account = false;

    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);

    try std.testing.expect(!main_mod.shouldScheduleBackgroundAccountNameRefresh(&reg));
}

test "Scenario: Given only another user has missing grouped team names when checking background refresh then it is still scheduled" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Backup Workspace");
    try appendAccount(gpa, &reg, "user-OTHER::acct-OTHER-A", "other@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-OTHER::acct-OTHER-B", "other@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);

    try std.testing.expect(main_mod.shouldScheduleBackgroundAccountNameRefresh(&reg));
}

test "Scenario: Given login with missing account names when refreshing metadata then it issues at most one request" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);

    var info = try parseAuthInfoWithIds(gpa, "user@example.com", "team", shared_user_id, primary_account_id);
    defer info.deinit(gpa);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = primary_account_id;
    const changed = try main_mod.refreshAccountNamesAfterLogin(gpa, &reg, &info, mockAccountNameFetcher);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[1].account_name.?, "Backup Workspace"));
}

test "Scenario: Given switched account with missing account names when refreshing metadata then it issues at most one request" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = primary_account_id;
    const changed = try main_mod.refreshAccountNamesAfterSwitch(gpa, codex_home, &reg, mockAccountNameFetcher);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[1].account_name.?, "Backup Workspace"));
}

test "Scenario: Given api disabled while background account-name refresh is in flight when it finishes then the latest api config is preserved" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    mutate_registry_during_account_fetch = true;
    mutate_registry_codex_home = codex_home;
    try main_mod.runBackgroundAccountNameRefresh(gpa, codex_home, mockAccountNameFetcherWithRegistryMutation);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(!loaded.api.account);
    try std.testing.expect(!loaded.api.usage);
    try std.testing.expect(loaded.accounts.items[0].account_name == null);
    try std.testing.expect(loaded.accounts.items[1].account_name == null);
}

test "Scenario: Given grouped stored snapshots without active auth when running background account-name refresh then it updates the missing names" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshotWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    try main_mod.runBackgroundAccountNameRefresh(gpa, codex_home, mockAccountNameFetcher);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[1].account_name.?, "Backup Workspace"));
}

test "Scenario: Given grouped stored snapshots with multiple tokens when running background account-name refresh then it prefers the newest last_refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshotWithIdsAndLastRefresh(
        gpa,
        codex_home,
        "user@example.com",
        "team",
        shared_user_id,
        primary_account_id,
        "stale-token",
        "2026-03-20T00:00:00Z",
    );
    try writeAccountSnapshotWithIdsAndLastRefresh(
        gpa,
        codex_home,
        "user@example.com",
        "team",
        shared_user_id,
        secondary_account_id,
        "fresh-token",
        "2026-03-21T00:00:00Z",
    );

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = secondary_account_id;
    try main_mod.runBackgroundAccountNameRefresh(gpa, codex_home, mockAccountNameFetcherRequiringFreshToken);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[1].account_name.?, "Backup Workspace"));
}

test "Scenario: Given grouped team names with only a stored plus snapshot for the same user when running background account-name refresh then it updates the team records" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ primary_account_id, "same-user@example.com", "", .team);
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ secondary_account_id, "same-user@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Old Backup Workspace");
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ tertiary_account_id, "same-user@example.com", "", .plus);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeAccountSnapshotWithIds(gpa, codex_home, "same-user@example.com", "plus", shared_user_id, tertiary_account_id);

    resetMockAccountNameFetcher();
    try main_mod.runBackgroundAccountNameRefresh(gpa, codex_home, mockAccountNameFetcher);

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, loaded.accounts.items[1].account_name.?, "Backup Workspace"));
    try std.testing.expect(loaded.accounts.items[2].account_name == null);
}

test "Scenario: Given single-file import with missing account names when refreshing metadata then it issues at most one request" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);

    var info = try parseAuthInfoWithIds(gpa, "user@example.com", "team", shared_user_id, primary_account_id);
    defer info.deinit(gpa);

    resetMockAccountNameFetcher();
    const changed = try main_mod.refreshAccountNamesAfterImport(gpa, &reg, false, .single_file, &info, mockAccountNameFetcher);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
}

test "Scenario: Given directory import or purge when refreshing account names then it issues zero requests" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);

    var info = try parseAuthInfoWithIds(gpa, "user@example.com", "team", shared_user_id, primary_account_id);
    defer info.deinit(gpa);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterImport(gpa, &reg, false, .scanned, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesAfterImport(gpa, &reg, true, .single_file, &info, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
}

test "Scenario: Given list refresh when only other users have missing account names then it skips the request" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Backup Workspace");
    try appendAccount(gpa, &reg, "user-OTHER::acct-OTHER", "other@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
}

test "Scenario: Given list refresh with missing active-user account names when refreshing metadata then it issues one request" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, primary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, secondary_record_key, "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-OTHER::acct-OTHER", "other@example.com", "", .team);
    try registry.setActiveAccountKey(gpa, &reg, primary_record_key);
    try writeActiveAuthWithIds(gpa, codex_home, "user@example.com", "team", shared_user_id, primary_account_id);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = primary_account_id;
    const changed = try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[1].account_name.?, "Backup Workspace"));

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
}

test "Scenario: Given list refresh with team names missing under the same user when refreshing metadata then it updates the team records" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ primary_account_id, "same-user@example.com", "", .team);
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ secondary_account_id, "same-user@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Old Backup Workspace");
    try appendAccount(gpa, &reg, shared_user_id ++ "::" ++ tertiary_account_id, "same-user@example.com", "", .plus);
    try registry.setActiveAccountKey(gpa, &reg, shared_user_id ++ "::" ++ tertiary_account_id);
    try writeActiveAuthWithIds(gpa, codex_home, "same-user@example.com", "plus", shared_user_id, tertiary_account_id);

    resetMockAccountNameFetcher();
    expected_mock_account_name_fetch_account_id = tertiary_account_id;
    const changed = try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), mock_account_name_fetch_count);
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[0].account_name.?, "Primary Workspace"));
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[1].account_name.?, "Backup Workspace"));
    try std.testing.expect(reg.accounts.items[2].account_name == null);

    resetMockAccountNameFetcher();
    try std.testing.expect(!(try main_mod.refreshAccountNamesForList(gpa, codex_home, &reg, mockAccountNameFetcher)));
    try std.testing.expectEqual(@as(usize, 0), mock_account_name_fetch_count);
}

test "Scenario: Given removed active account with remaining accounts when reconciling then the best usage account becomes active" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const gamma_key = try bdd.accountKeyForEmailAlloc(gpa, "gamma@example.com");
    defer gpa.free(gamma_key);
    try appendAccount(gpa, &reg, alpha_key, "alpha@example.com", "", .plus);
    try appendAccount(gpa, &reg, gamma_key, "gamma@example.com", "", .team);

    const now = std.time.timestamp();
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 100, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .plus,
    };
    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    try writeSnapshot(gpa, codex_home, "alpha@example.com", "plus");
    try writeSnapshot(gpa, codex_home, "gamma@example.com", "team");

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, gamma_key));

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    const gamma_auth = try bdd.authJsonWithEmailPlan(gpa, "gamma@example.com", "team");
    defer gpa.free(gamma_auth);
    try std.testing.expectEqualStrings(gamma_auth, active_auth);
}

test "Scenario: Given stale active key with remaining accounts when reconciling after remove then it is treated as unset" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const gamma_key = try bdd.accountKeyForEmailAlloc(gpa, "gamma@example.com");
    defer gpa.free(gamma_key);
    try appendAccount(gpa, &reg, alpha_key, "alpha@example.com", "", .plus);
    try appendAccount(gpa, &reg, gamma_key, "gamma@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-stale::acct-stale");
    reg.active_account_activated_at_ms = 1;

    const now = std.time.timestamp();
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 100, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .plus,
    };
    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    try writeSnapshot(gpa, codex_home, "alpha@example.com", "plus");
    try writeSnapshot(gpa, codex_home, "gamma@example.com", "team");

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, gamma_key));

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    const gamma_auth = try bdd.authJsonWithEmailPlan(gpa, "gamma@example.com", "team");
    defer gpa.free(gamma_auth);
    try std.testing.expectEqualStrings(gamma_auth, active_auth);
}

test "Scenario: Given no remaining accounts when reconciling after remove then active auth is deleted" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given newer registry schema when loading help config then default help settings are used" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 999,
        \\  "auto_switch": {
        \\    "enabled": true,
        \\    "threshold_5h_percent": 1,
        \\    "threshold_weekly_percent": 1
        \\  },
        \\  "api": {
        \\    "usage": true
        \\  },
        \\  "accounts": []
        \\}
        ,
    });

    const help_cfg = main_mod.loadHelpConfig(gpa, codex_home);
    try std.testing.expectEqual(registry.defaultAutoSwitchConfig(), help_cfg.auto_switch);
    try std.testing.expectEqual(registry.defaultApiConfig(), help_cfg.api);
}
