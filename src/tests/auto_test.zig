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
    const active_account_id = try bdd.accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);

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
    const active_account_id = try bdd.accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);

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
    const active_account_id = try bdd.accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);

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
    const active_account_id = try bdd.accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);

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
    const low_account_id = try bdd.accountIdForEmailAlloc(gpa, "low@example.com");
    defer gpa.free(low_account_id);
    try registry.setActiveAccount(gpa, &reg, low_account_id);

    const low_auth = try bdd.authJsonWithEmailPlan(gpa, "low@example.com", "pro");
    defer gpa.free(low_auth);
    const fresh_auth = try bdd.authJsonWithEmailPlan(gpa, "fresh@example.com", "pro");
    defer gpa.free(fresh_auth);

    const low_path = try registry.accountAuthPath(gpa, codex_home, low_account_id);
    defer gpa.free(low_path);
    const fresh_account_id = try bdd.accountIdForEmailAlloc(gpa, "fresh@example.com");
    defer gpa.free(fresh_account_id);
    const fresh_path = try registry.accountAuthPath(gpa, codex_home, fresh_account_id);
    defer gpa.free(fresh_path);
    const active_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_path);

    try std.fs.cwd().writeFile(.{ .sub_path = low_path, .data = low_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = fresh_path, .data = fresh_auth });
    try std.fs.cwd().writeFile(.{ .sub_path = active_path, .data = low_auth });

    try std.testing.expect(try auto.maybeAutoSwitch(gpa, codex_home, &reg));
    try std.testing.expect(reg.active_account_id != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_id.?, fresh_account_id));

    const active_data = try bdd.readFileAlloc(gpa, active_path);
    defer gpa.free(active_data);
    try std.testing.expect(std.mem.eql(u8, active_data, fresh_auth));
}

test "Scenario: Given linux service unit when rendering then daemon watch command is included" {
    const gpa = std.testing.allocator;
    const unit = try auto.linuxUnitText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(unit);

    try std.testing.expect(std.mem.indexOf(u8, unit, "Description=codex-auth auto-switch daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"CODEX_HOME=/tmp/custom-codex-home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=\"CODEX_AUTH_VERSION=") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=\"/tmp/codex-auth\" daemon --watch") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Restart=always") != null);
}

test "Scenario: Given mac plist when rendering then CODEX_HOME environment is preserved" {
    const gpa = std.testing.allocator;
    const plist = try auto.macPlistText(gpa, "/tmp/codex-auth", "/tmp/custom-codex-home");
    defer gpa.free(plist);

    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CODEX_HOME</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/tmp/custom-codex-home</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CODEX_AUTH_VERSION</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>daemon</string>") != null);
}

test "Scenario: Given windows task action when rendering then it preserves CODEX_HOME and launches via powershell" {
    const gpa = std.testing.allocator;
    const action = try auto.windowsTaskAction(gpa, "C:\\Program Files\\codex-auth.exe", "D:\\Codex Home");
    defer gpa.free(action);

    try std.testing.expect(std.mem.indexOf(u8, action, "powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -Command") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "$env:CODEX_HOME = 'D:\\Codex Home'") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "$env:CODEX_AUTH_VERSION = '") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "& 'C:\\Program Files\\codex-auth.exe' daemon --watch") != null);
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
    try std.testing.expect(auto.parseWindowsTaskStateOutput("3\r\n") == .stopped);
    try std.testing.expect(auto.parseWindowsTaskStateOutput("garbled\r\n") == .unknown);
}

test "Scenario: Given auto status when rendering then configured thresholds are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try auto.writeStatus(&aw.writer, .{
        .enabled = true,
        .runtime = .running,
        .threshold_5h_percent = 12,
        .threshold_weekly_percent = 8,
    });

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "auto-switch: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service: running") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thresholds: 5h<12%, weekly<8%") != null);
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
    const active_account_id = try bdd.accountIdForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_id);
    try registry.setActiveAccount(gpa, &reg, active_account_id);

    try std.testing.expect(!(try auto.refreshTrackedActiveUsage(gpa, codex_home, &reg)));
    const idx = bdd.findAccountIndexByEmail(&reg, "active@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[idx].last_usage == null);
}

test "Scenario: Given unchanged rollout after switching accounts when refreshing usage then it is not reassigned" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/run-1");

    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);
    try bdd.appendAccount(gpa, &reg, "a@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "b@example.com", "", null);
    const account_id_a = try bdd.accountIdForEmailAlloc(gpa, "a@example.com");
    defer gpa.free(account_id_a);
    try registry.setActiveAccount(gpa, &reg, account_id_a);

    try tmp.dir.writeFile(.{ .sub_path = "sessions/run-1/rollout-a.jsonl", .data = rollout_line ++ "\n" });

    try std.testing.expect(try auto.refreshTrackedActiveUsage(gpa, codex_home, &reg));
    const a_idx = bdd.findAccountIndexByEmail(&reg, "a@example.com") orelse return error.TestExpectedEqual;
    const b_idx = bdd.findAccountIndexByEmail(&reg, "b@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(reg.accounts.items[a_idx].last_usage != null);

    const account_id_b = try bdd.accountIdForEmailAlloc(gpa, "b@example.com");
    defer gpa.free(account_id_b);
    try registry.setActiveAccount(gpa, &reg, account_id_b);
    try std.testing.expect(!(try auto.refreshTrackedActiveUsage(gpa, codex_home, &reg)));
    try std.testing.expect(reg.accounts.items[b_idx].last_usage == null);
}
