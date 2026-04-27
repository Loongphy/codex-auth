const std = @import("std");
const codex_auth = @import("codex_auth");

const account_api = codex_auth.api.account;
const account_name_refresh = codex_auth.auth.account;
const app_runtime = codex_auth.core.runtime;
const cli = codex_auth.cli;
const fixtures = @import("support/fixtures.zig");
const test_fixtures = fixtures;
const main_mod = codex_auth.workflows;
const registry = codex_auth.registry;

const ForegroundUsageRefreshTarget = main_mod.ForegroundUsageRefreshTarget;
const SwitchLiveRefreshPolicy = main_mod.SwitchLiveRefreshPolicy;
const SwitchLiveRuntime = main_mod.SwitchLiveRuntime;
const buildRemoveLiveActionDisplay = main_mod.buildRemoveLiveActionDisplay;
const buildSwitchLiveActionDisplay = main_mod.buildSwitchLiveActionDisplay;
const isHandledCliError = main_mod.isHandledCliError;
const liveTtyPreflightError = main_mod.liveTtyPreflightError;
const loadInitialLiveSelectionDisplay = main_mod.loadInitialLiveSelectionDisplay;
const loadStoredSwitchSelectionDisplay = main_mod.loadStoredSwitchSelectionDisplay;
const loadStoredSwitchSelectionDisplayWithRefreshError = main_mod.loadStoredSwitchSelectionDisplayWithRefreshError;
const mergeSwitchLiveRefreshIntoLatest = main_mod.mergeSwitchLiveRefreshIntoLatest;
const nowMilliseconds = main_mod.nowMilliseconds;
const removeLiveRuntimeApplySelection = main_mod.removeLiveRuntimeApplySelection;
const runBackgroundAccountNameRefreshWithLockAcquirer = main_mod.runBackgroundAccountNameRefreshWithLockAcquirer;
const switch_live_default_refresh_interval_ms = main_mod.switch_live_default_refresh_interval_ms;
const switchLiveRuntimeApplySelection = main_mod.switchLiveRuntimeApplySelection;
const findAccountIndexByAccountKeyConst = main_mod.findAccountIndexByAccountKeyConst;
const nowSeconds = main_mod.nowSeconds;
const mapSwitchUsageOverridesToLatest = main_mod.mapSwitchUsageOverridesToLatest;
const replaceOptionalOwnedString = main_mod.replaceOptionalOwnedString;

test "background account-name refresh returns early when another refresh holds the lock" {
    const TestState = struct {
        var fetch_count: usize = 0;

        fn lockUnavailable(_: std.mem.Allocator, _: []const u8) !?account_name_refresh.BackgroundRefreshLock {
            return null;
        }

        fn unexpectedFetcher(
            allocator: std.mem.Allocator,
            access_token: []const u8,
            account_id: []const u8,
        ) !account_api.FetchResult {
            _ = allocator;
            _ = access_token;
            _ = account_id;
            fetch_count += 1;
            return error.TestUnexpectedFetch;
        }
    };

    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    TestState.fetch_count = 0;
    try runBackgroundAccountNameRefreshWithLockAcquirer(
        gpa,
        codex_home,
        TestState.unexpectedFetcher,
        TestState.lockUnavailable,
    );
    try std.testing.expectEqual(@as(usize, 0), TestState.fetch_count);
}

test "handled cli errors include missing node" {
    try std.testing.expect(isHandledCliError(error.NodeJsRequired));
}

fn saveLivePolicyTestRegistry(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    api_config: registry.ApiConfig,
    live_config: registry.LiveConfig,
) !void {
    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = api_config,
        .live = live_config,
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(allocator);
    try registry.saveRegistry(allocator, codex_home, &reg);
}

fn expectInitialLiveSelectionPolicy(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: ForegroundUsageRefreshTarget,
    api_mode: cli.types.ApiMode,
    expected: SwitchLiveRefreshPolicy,
) !void {
    var loaded = try loadInitialLiveSelectionDisplay(allocator, codex_home, target, api_mode);
    defer loaded.display.deinit(allocator);
    defer if (loaded.refresh_error_name) |name| allocator.free(name);

    try std.testing.expectEqual(expected.usage_api_enabled, loaded.policy.usage_api_enabled);
    try std.testing.expectEqual(expected.account_api_enabled, loaded.policy.account_api_enabled);
    try std.testing.expectEqual(expected.interval_ms, loaded.policy.interval_ms);
    try std.testing.expectEqualStrings(expected.label, loaded.policy.label);
    try std.testing.expect(loaded.refresh_error_name == null);
}

fn appendLiveMergeTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    email: []const u8,
    alias: []const u8,
) !void {
    const sep = std.mem.lastIndexOf(u8, account_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = account_key[0..sep];
    const chatgpt_account_id = account_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = .team,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn writeLiveActionTestSnapshot(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
    email: []const u8,
    plan: []const u8,
) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);
    const auth_json = try fixtures.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.Io.Dir.cwd().writeFile(app_runtime.io(), .{ .sub_path = auth_path, .data = auth_json });
}

fn sleepLiveRefreshTask(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(800), .awake) catch {};
}

test "live refresh interval uses the shared live config cadence" {
    try std.testing.expectEqual(@as(i64, 30_000), switch_live_default_refresh_interval_ms);
}

test "initial live selection display uses stored api defaults for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, registry.defaultApiConfig(), registry.defaultLiveConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .default, .{
            .usage_api_enabled = true,
            .account_api_enabled = true,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "api",
        });
    }
}

test "initial live selection display preserves mixed stored api defaults for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, .{
        .usage = false,
        .account = true,
    }, registry.defaultLiveConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .default, .{
            .usage_api_enabled = false,
            .account_api_enabled = true,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "api",
        });
    }
}

test "initial live selection display honors explicit api mode overrides for list, switch, and remove" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, .{
        .usage = false,
        .account = false,
    }, registry.defaultLiveConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .force_api, .{
            .usage_api_enabled = true,
            .account_api_enabled = true,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "api",
        });
    }

    try saveLivePolicyTestRegistry(gpa, codex_home, registry.defaultApiConfig(), registry.defaultLiveConfig());

    inline for ([_]ForegroundUsageRefreshTarget{ .list, .switch_account, .remove_account }) |target| {
        try expectInitialLiveSelectionPolicy(gpa, codex_home, target, .skip_api, .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        });
    }
}

test "initial live selection display uses configured live refresh interval for api and local modes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    try saveLivePolicyTestRegistry(gpa, codex_home, registry.defaultApiConfig(), .{ .interval_seconds = 45 });
    try expectInitialLiveSelectionPolicy(gpa, codex_home, .list, .default, .{
        .usage_api_enabled = true,
        .account_api_enabled = true,
        .interval_ms = 45_000,
        .label = "api",
    });

    try expectInitialLiveSelectionPolicy(gpa, codex_home, .list, .skip_api, .{
        .usage_api_enabled = false,
        .account_api_enabled = false,
        .interval_ms = 45_000,
        .label = "local",
    });
}

test "live refresh merge preserves accounts newly added to the latest registry" {
    const gpa = std.testing.allocator;

    var base: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer base.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &base, "user-alpha::acct-alpha", "alpha@example.com", "alpha");

    var refreshed: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer refreshed.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &refreshed, "user-alpha::acct-alpha", "alpha@example.com", "alpha");
    refreshed.accounts.items[0].account_name = try gpa.dupe(u8, "Alpha Workspace");

    var latest: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer latest.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &latest, "user-alpha::acct-alpha", "alpha@example.com", "alpha");
    try appendLiveMergeTestAccount(gpa, &latest, "user-beta::acct-beta", "beta@example.com", "beta");

    const changed = try mergeSwitchLiveRefreshIntoLatest(gpa, &latest, &base, &refreshed);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 2), latest.accounts.items.len);

    const alpha_idx = findAccountIndexByAccountKeyConst(&latest, "user-alpha::acct-alpha") orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&latest, "user-beta::acct-beta") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Alpha Workspace", latest.accounts.items[alpha_idx].account_name.?);
    try std.testing.expect(latest.accounts.items[beta_idx].account_name == null);

    const usage_overrides = try gpa.alloc(?[]const u8, refreshed.accounts.items.len);
    defer {
        for (usage_overrides) |value| {
            if (value) |text| gpa.free(@constCast(text));
        }
        gpa.free(usage_overrides);
    }
    for (usage_overrides) |*value| value.* = null;
    usage_overrides[0] = try gpa.dupe(u8, "403");

    const mapped_usage_overrides = try mapSwitchUsageOverridesToLatest(gpa, &latest, &refreshed, usage_overrides);
    defer {
        for (mapped_usage_overrides) |value| {
            if (value) |text| gpa.free(@constCast(text));
        }
        gpa.free(mapped_usage_overrides);
    }

    try std.testing.expectEqual(@as(usize, 2), mapped_usage_overrides.len);
    try std.testing.expectEqualStrings("403", mapped_usage_overrides[alpha_idx].?);
    try std.testing.expect(mapped_usage_overrides[beta_idx] == null);
}

test "switch live action patches the current display after switching" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try fixtures.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Registry Beta");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "PreviousRefreshError"),
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    runtime.mutex.lockUncancelable(live_io);
    runtime.next_refresh_not_before_ms = nowMilliseconds() - 1;
    runtime.refresh_interval_ms = 1;
    runtime.mode_label = "stale";
    runtime.last_refresh_started_at_ms = null;
    runtime.last_refresh_finished_at_ms = null;
    runtime.last_refresh_duration_ms = null;
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .switch_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);
    const alpha_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, alpha_key) orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, beta_key) orelse return error.TestExpectedEqual;
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[beta_idx].account_name, "Display Beta");
    current_display.display.usage_overrides[alpha_idx] = try gpa.dupe(u8, "403");
    current_display.display.usage_overrides[beta_idx] = try gpa.dupe(u8, "401");

    const action_started_ms = nowMilliseconds();
    const outcome = try switchLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        beta_key,
    );
    const action_finished_ms = nowMilliseconds();
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expectEqualStrings("Switched to Registry Beta", outcome.action_message.?);
    try std.testing.expectEqualStrings(beta_key, outcome.updated_display.reg.active_account_key.?);
    try std.testing.expectEqual(@as(usize, 2), outcome.updated_display.reg.accounts.items.len);
    try std.testing.expectEqualStrings("Registry Beta", outcome.updated_display.reg.accounts.items[beta_idx].account_name.?);
    try std.testing.expectEqualStrings("403", outcome.updated_display.usage_overrides[alpha_idx].?);
    try std.testing.expectEqualStrings("401", outcome.updated_display.usage_overrides[beta_idx].?);
    try std.testing.expect(runtime.last_refresh_error_name != null);
    try std.testing.expectEqualStrings("PreviousRefreshError", runtime.last_refresh_error_name.?);
    try std.testing.expectEqualStrings("local", runtime.mode_label);
    try std.testing.expectEqual(switch_live_default_refresh_interval_ms, runtime.refresh_interval_ms);
    try std.testing.expect(runtime.last_refresh_started_at_ms != null);
    try std.testing.expect(runtime.last_refresh_finished_at_ms != null);
    try std.testing.expect(runtime.last_refresh_duration_ms != null);
    try std.testing.expect(runtime.last_refresh_started_at_ms.? >= action_started_ms);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? >= runtime.last_refresh_started_at_ms.?);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? <= action_finished_ms);
    try std.testing.expectEqual(
        runtime.last_refresh_finished_at_ms.? + switch_live_default_refresh_interval_ms,
        runtime.next_refresh_not_before_ms,
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqualStrings(beta_key, loaded.active_account_key.?);
}

test "switch live action does not wait for an in-flight refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try fixtures.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        null,
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .switch_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);

    const started_ms = nowMilliseconds();
    const outcome = try switchLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        beta_key,
    );
    const elapsed_ms = nowMilliseconds() - started_ms;
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqualStrings("Switched to beta@example.com", outcome.action_message.?);
    try std.testing.expectEqual(@as(u64, 1), runtime.display_generation);
}

test "remove live action patches the current display after deleting the active account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try fixtures.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Registry Alpha");
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Registry Beta");
    const future_primary_reset_at = nowSeconds() + 60 * 60;
    const future_secondary_reset_at = nowSeconds() + 7 * 24 * 60 * 60;
    reg.accounts.items[1].last_usage = try registry.cloneRateLimitSnapshot(gpa, .{
        .primary = .{ .used_percent = 12.0, .window_minutes = 300, .resets_at = future_primary_reset_at },
        .secondary = .{ .used_percent = 18.0, .window_minutes = 10080, .resets_at = future_secondary_reset_at },
        .credits = null,
        .plan_type = .plus,
    });
    reg.accounts.items[1].last_usage_at = nowSeconds() - 60;
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .remove_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "PreviousRefreshError"),
    );
    defer runtime.deinit();

    const selected = [_][]const u8{alpha_key};
    const live_io = runtime.io_impl.io();
    runtime.mutex.lockUncancelable(live_io);
    runtime.next_refresh_not_before_ms = nowMilliseconds() - 1;
    runtime.refresh_interval_ms = 1;
    runtime.mode_label = "stale";
    runtime.last_refresh_started_at_ms = null;
    runtime.last_refresh_finished_at_ms = null;
    runtime.last_refresh_duration_ms = null;
    runtime.mutex.unlock(live_io);

    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .remove_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);
    const alpha_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, alpha_key) orelse return error.TestExpectedEqual;
    const beta_idx = findAccountIndexByAccountKeyConst(&current_display.display.reg, beta_key) orelse return error.TestExpectedEqual;
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[alpha_idx].account_name, "Display Alpha");
    _ = try replaceOptionalOwnedString(gpa, &current_display.display.reg.accounts.items[beta_idx].account_name, "Display Beta");
    current_display.display.usage_overrides[alpha_idx] = try gpa.dupe(u8, "403");
    current_display.display.usage_overrides[beta_idx] = try gpa.dupe(u8, "401");

    const action_started_ms = nowMilliseconds();
    const outcome = try removeLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        &selected,
    );
    const action_finished_ms = nowMilliseconds();
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expectEqualStrings("Removed 1 account(s): alpha@example.com / Registry Alpha", outcome.action_message.?);
    try std.testing.expectEqual(@as(usize, 1), outcome.updated_display.reg.accounts.items.len);
    try std.testing.expect(findAccountIndexByAccountKeyConst(&outcome.updated_display.reg, alpha_key) == null);
    try std.testing.expectEqualStrings(beta_key, outcome.updated_display.reg.active_account_key.?);
    try std.testing.expectEqualStrings("Registry Beta", outcome.updated_display.reg.accounts.items[0].account_name.?);
    try std.testing.expectEqual(@as(usize, 1), outcome.updated_display.usage_overrides.len);
    try std.testing.expectEqualStrings("401", outcome.updated_display.usage_overrides[0].?);
    try std.testing.expect(runtime.last_refresh_error_name != null);
    try std.testing.expectEqualStrings("PreviousRefreshError", runtime.last_refresh_error_name.?);
    try std.testing.expectEqualStrings("local", runtime.mode_label);
    try std.testing.expectEqual(switch_live_default_refresh_interval_ms, runtime.refresh_interval_ms);
    try std.testing.expect(runtime.last_refresh_started_at_ms != null);
    try std.testing.expect(runtime.last_refresh_finished_at_ms != null);
    try std.testing.expect(runtime.last_refresh_duration_ms != null);
    try std.testing.expect(runtime.last_refresh_started_at_ms.? >= action_started_ms);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? >= runtime.last_refresh_started_at_ms.?);
    try std.testing.expect(runtime.last_refresh_finished_at_ms.? <= action_finished_ms);
    try std.testing.expectEqual(
        runtime.last_refresh_finished_at_ms.? + switch_live_default_refresh_interval_ms,
        runtime.next_refresh_not_before_ms,
    );

    var loaded = try registry.loadRegistry(gpa, codex_home);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expect(findAccountIndexByAccountKeyConst(&loaded, alpha_key) == null);
    try std.testing.expectEqualStrings(beta_key, loaded.active_account_key.?);
}

test "remove live action does not wait for an in-flight refresh" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    const alpha_key = try fixtures.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const beta_key = try fixtures.accountKeyForEmailAlloc(gpa, "beta@example.com");
    defer gpa.free(beta_key);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try appendLiveMergeTestAccount(gpa, &reg, alpha_key, "alpha@example.com", "");
    try appendLiveMergeTestAccount(gpa, &reg, beta_key, "beta@example.com", "");
    try registry.setActiveAccountKey(gpa, &reg, alpha_key);
    try registry.saveRegistry(gpa, codex_home, &reg);
    try writeLiveActionTestSnapshot(gpa, codex_home, alpha_key, "alpha@example.com", "team");
    try writeLiveActionTestSnapshot(gpa, codex_home, beta_key, "beta@example.com", "plus");

    var runtime = SwitchLiveRuntime.init(
        gpa,
        codex_home,
        .remove_account,
        .skip_api,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        null,
    );
    defer runtime.deinit();

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    const selected = [_][]const u8{beta_key};
    var current_display = try loadStoredSwitchSelectionDisplay(gpa, codex_home, .remove_account, .skip_api);
    defer current_display.display.deinit(gpa);
    defer if (current_display.refresh_error_name) |name| gpa.free(name);

    const started_ms = nowMilliseconds();
    const outcome = try removeLiveRuntimeApplySelection(
        @ptrCast(&runtime),
        gpa,
        current_display.display.borrowed(),
        &selected,
    );
    const elapsed_ms = nowMilliseconds() - started_ms;
    defer {
        if (outcome.action_message) |message| gpa.free(message);
        var owned_display = outcome.updated_display;
        owned_display.deinit(gpa);
    }

    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqualStrings("Removed 1 account(s): beta@example.com", outcome.action_message.?);
    try std.testing.expectEqual(@as(u64, 1), runtime.display_generation);
}

test "live runtime deinit cancels an in-flight refresh promptly" {
    const gpa = std.testing.allocator;

    var runtime = SwitchLiveRuntime.init(
        gpa,
        ".",
        .list,
        .default,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        null,
    );

    const live_io = runtime.io_impl.io();
    const refresh_task = live_io.concurrent(sleepLiveRefreshTask, .{live_io}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    runtime.mutex.lockUncancelable(live_io);
    runtime.refresh_task = refresh_task;
    runtime.in_flight = true;
    runtime.last_refresh_started_at_ms = nowMilliseconds();
    runtime.mutex.unlock(live_io);

    const started_ms = nowMilliseconds();
    runtime.deinit();
    const elapsed_ms = nowMilliseconds() - started_ms;

    try std.testing.expect(elapsed_ms < 500);
}

test "live fallback display preserves the refresh error name" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try app_runtime.realPathFileAlloc(gpa, tmp.dir, ".");
    defer gpa.free(codex_home);

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);
    try registry.saveRegistry(gpa, codex_home, &reg);

    var loaded = try loadStoredSwitchSelectionDisplayWithRefreshError(
        gpa,
        codex_home,
        .switch_account,
        .skip_api,
        error.NodeJsRequired,
    );
    defer loaded.display.deinit(gpa);
    defer if (loaded.refresh_error_name) |name| gpa.free(name);

    try std.testing.expectEqualStrings("NodeJsRequired", loaded.refresh_error_name.?);
}

test "live tty preflight reports command-specific errors" {
    try std.testing.expect(liveTtyPreflightError(.list, true, true) == null);
    try std.testing.expect(liveTtyPreflightError(.switch_account, true, true) == null);
    try std.testing.expect(liveTtyPreflightError(.remove_account, true, true) == null);

    try std.testing.expect(liveTtyPreflightError(.list, false, true).? == error.ListLiveRequiresTty);
    try std.testing.expect(liveTtyPreflightError(.switch_account, true, false).? == error.SwitchSelectionRequiresTty);
    try std.testing.expect(liveTtyPreflightError(.remove_account, false, false).? == error.RemoveSelectionRequiresTty);
}

test "live tui output loss is a handled cli error" {
    try std.testing.expect(isHandledCliError(error.TuiOutputUnavailable));
}

test "buildStatusLine releases mutex on allocation failure" {
    const gpa = std.testing.allocator;

    var reg: registry.Registry = .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
    defer reg.deinit(gpa);

    var runtime = SwitchLiveRuntime.init(
        gpa,
        ".",
        .list,
        .default,
        false,
        .{
            .usage_api_enabled = false,
            .account_api_enabled = false,
            .interval_ms = switch_live_default_refresh_interval_ms,
            .label = "local",
        },
        try gpa.dupe(u8, "NodeJsRequired"),
    );
    defer runtime.deinit();

    var failing_allocator_state = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const failing_allocator = failing_allocator_state.allocator();

    try std.testing.expectError(
        error.OutOfMemory,
        runtime.buildStatusLine(failing_allocator, .{
            .reg = &reg,
            .usage_overrides = null,
        }),
    );

    try std.testing.expect(runtime.mutex.tryLock());
    runtime.mutex.unlock(app_runtime.io());
}

// Tests live in separate files but are pulled in by main.zig for zig test.
