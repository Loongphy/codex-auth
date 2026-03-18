const std = @import("std");
const auto = @import("../auto.zig");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

const rollout_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:00Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":92.0,\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":49.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}";

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

fn partialServiceArtifactPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "partial-service-artifact" });
}

fn installServiceWithPartialArtifact(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    _: []const u8,
) !void {
    const artifact_path = try partialServiceArtifactPath(allocator, codex_home);
    defer allocator.free(artifact_path);
    try std.fs.cwd().writeFile(.{ .sub_path = artifact_path, .data = "partial" });
    return error.TestInstallFailed;
}

fn uninstallPartialServiceArtifact(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const artifact_path = try partialServiceArtifactPath(allocator, codex_home);
    defer allocator.free(artifact_path);
    std.fs.cwd().deleteFile(artifact_path) catch |err| switch (err) {
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

    const idx = auto.bestAutoSwitchCandidateIndex(&reg, std.time.timestamp()) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, reg.accounts.items[idx].email, "fresh@example.com"));
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

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, std.time.timestamp()));
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

    try std.testing.expect(auto.shouldSwitchCurrent(&reg, std.time.timestamp()));
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

    try std.testing.expect(!auto.shouldSwitchCurrent(&reg, std.time.timestamp()));
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
    var tmp = std.testing.tmpDir(.{});
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

    try std.fs.cwd().writeFile(.{ .sub_path = low_path, .data = low_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = active_path, .data = low_auth });

    try std.testing.expect(try auto.maybeAutoSwitch(gpa, codex_home, &reg));
    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, fresh_account_id));

    const active_data = try bdd.readFileAlloc(gpa, active_path);
    defer gpa.free(active_data);
    try std.testing.expect(std.mem.eql(u8, active_data, fresh_auth));
}

test "Scenario: Given linux service unit when rendering then oneshot daemon command is included" {
    const gpa = std.testing.allocator;
    const unit = try auto.linuxUnitText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Description=codex-auth auto-switch check") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Type=oneshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"CODEX_AUTH_VERSION=") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=\"/tmp/codex-auth\" daemon --once") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Restart=always") == null);
}

test "Scenario: Given linux timer unit when rendering then it schedules the oneshot service every minute" {
    const gpa = std.testing.allocator;
    const timer = try auto.linuxTimerText(gpa);
    defer gpa.free(timer);

    try std.testing.expect(std.mem.indexOf(u8, timer, "Description=Run codex-auth auto-switch every minute") != null);
    try std.testing.expect(std.mem.indexOf(u8, timer, "OnBootSec=1min") != null);
    try std.testing.expect(std.mem.indexOf(u8, timer, "OnUnitActiveSec=1min") != null);
    try std.testing.expect(std.mem.indexOf(u8, timer, "Unit=codex-auth-autoswitch.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, timer, "WantedBy=timers.target") != null);
}

test "Scenario: Given mac plist when rendering then it includes version metadata and daemon args" {
    const gpa = std.testing.allocator;
    const plist = try auto.macPlistText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(plist);

    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CODEX_AUTH_VERSION</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>daemon</string>") != null);
}

test "Scenario: Given windows task action when rendering then it launches the helper directly without cmd" {
    const gpa = std.testing.allocator;
    const action = try auto.windowsTaskAction(gpa, "C:\\Program Files\\codex-auth\\codex-auth-auto.exe");
    defer gpa.free(action);

    try std.testing.expect(std.mem.indexOf(u8, action, "cmd.exe /D /C") == null);
    try std.testing.expect(std.mem.indexOf(u8, action, "\"C:\\Program Files\\codex-auth\\codex-auth-auto.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "powershell.exe") == null);
    try std.testing.expect(action.len < 262);
}

test "Scenario: Given windows task match script when rendering then it validates both action and one-minute trigger" {
    const gpa = std.testing.allocator;
    const script = try auto.windowsTaskMatchScript(gpa);
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "Get-ScheduledTask -TaskName 'CodexAuthAutoSwitch' -ErrorAction SilentlyContinue") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Export-ScheduledTask -TaskName 'CodexAuthAutoSwitch'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Repetition.Interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$action.Execute + $args + '|TRIGGER:' + $interval") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "|TRIGGER:") != null);
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
    var tmp = std.testing.tmpDir(.{});
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
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(artifact_path, .{}));
}

test "Scenario: Given preflight failure when enabling auto-switch then registry is unchanged and installer is skipped" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(artifact_path, .{}));
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
    try std.testing.expect(std.mem.eql(u8, output, "auto-switch: from@example.com -> to@example.com\n"));
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
    try std.testing.expect(auto.parseWindowsTaskStateOutput("3\r\n") == .running);
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
    });

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "auto-switch: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service: running") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thresholds: 5h<12%, weekly<8%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "usage: local") != null);
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
    });

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "usage: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Warning: Usage refresh is currently using the ChatGPT usage API") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`codex-auth config api disable`") == null);
}

test "Scenario: Given missing sessions dir when refreshing active usage then it is skipped without error" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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

test "Scenario: Given api usage for active account when refreshing usage then it updates without rollout files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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

test "Scenario: Given api-only mode and api failure when refreshing usage then local usage stays untouched and local rollout state is unchanged" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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

test "Scenario: Given api failure when returning to local refresh after switching accounts then the pre-switch rollout is not assigned to the new active account" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
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
    var tmp = std.testing.tmpDir(.{});
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

    const base_time = @as(i128, std.time.nanoTimestamp());
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-d.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time, base_time);
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-c.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + std.time.ns_per_s, base_time + std.time.ns_per_s);
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-b.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (2 * std.time.ns_per_s), base_time + (2 * std.time.ns_per_s));
    }
    {
        var file = try tmp.dir.openFile("sessions/run-1/rollout-a.jsonl", .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (3 * std.time.ns_per_s), base_time + (3 * std.time.ns_per_s));
    }

    try std.testing.expect(!(try auto.refreshActiveUsage(gpa, codex_home, &reg)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage != null);
    try std.testing.expectEqual(@as(f64, 41.0), reg.accounts.items[idx].last_usage.?.primary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 777), reg.accounts.items[idx].last_usage_at.?);
}
