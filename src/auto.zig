const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const sessions = @import("sessions.zig");
const usage_api = @import("usage_api.zig");
const version = @import("version.zig");

const linux_service_name = "codex-auth-autoswitch.service";
const linux_timer_name = "codex-auth-autoswitch.timer";
const mac_label = "com.loongphy.codex-auth.auto";
const windows_task_name = "CodexAuthAutoSwitch";
const windows_helper_name = "codex-auth-auto.exe";
const windows_task_trigger_interval = "PT1M";
const lock_file_name = "auto-switch.lock";
const poll_interval_ns = 60 * std.time.ns_per_s;
pub const RuntimeState = enum { running, stopped, unknown };

const ansi = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[31m";
    const bold_red = "\x1b[1;31m";
    const green = "\x1b[32m";
    const bold = "\x1b[1m";
    const bold_green = "\x1b[1;32m";
    const yellow = "\x1b[33m";
};

pub const Status = struct {
    enabled: bool,
    runtime: RuntimeState,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
};

const service_version_env_name = "CODEX_AUTH_VERSION";

const CandidateScore = struct {
    value: i64,
    last_usage_at: i64,
    created_at: i64,
};

const DaemonLock = struct {
    file: std.fs.File,

    fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?DaemonLock {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", lock_file_name });
        defer allocator.free(path);
        var file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!(try tryExclusiveLock(file))) {
            file.close();
            return null;
        }
        return .{ .file = file };
    }

    fn release(self: *DaemonLock) void {
        self.file.unlock();
        self.file.close();
    }
};

fn tryExclusiveLock(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const range_off: windows.LARGE_INTEGER = 0;
        const range_len: windows.LARGE_INTEGER = 1;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &range_off,
            &range_len,
            null,
            windows.TRUE,
            windows.TRUE,
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        return true;
    }

    return try file.tryLock(.exclusive);
}

pub fn helpStateLabel(enabled: bool) []const u8 {
    return if (enabled) "ON" else "OFF";
}

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty();
}

pub fn printStatus(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const status = try getStatus(allocator, codex_home);
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try writeStatusWithColor(stdout.out(), status, colorEnabled());
    try cli.printUsageApiRiskWarning(status.api_usage_enabled);
}

pub fn getStatus(allocator: std.mem.Allocator, codex_home: []const u8) !Status {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    return .{
        .enabled = reg.auto_switch.enabled,
        .runtime = queryRuntimeState(allocator),
        .threshold_5h_percent = reg.auto_switch.threshold_5h_percent,
        .threshold_weekly_percent = reg.auto_switch.threshold_weekly_percent,
        .api_usage_enabled = reg.api.usage,
    };
}

pub fn writeStatus(out: *std.Io.Writer, status: Status) !void {
    try writeStatusWithColor(out, status, false);
}

fn writeStatusWithColor(out: *std.Io.Writer, status: Status, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("auto-switch: ");
    if (use_color) try out.writeAll(if (status.enabled) ansi.bold_green else ansi.bold_red);
    try out.writeAll(helpStateLabel(status.enabled));
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("service: ");
    if (use_color) try out.writeAll(switch (status.runtime) {
        .running => ansi.bold_green,
        .stopped => ansi.bold_red,
        .unknown => ansi.bold_red,
    });
    try out.writeAll(@tagName(status.runtime));
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("thresholds: ");
    if (use_color) try out.writeAll(ansi.yellow);
    try out.print(
        "5h<{d}%, weekly<{d}%",
        .{ status.threshold_5h_percent, status.threshold_weekly_percent },
    );
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("usage: ");
    if (use_color) try out.writeAll(ansi.yellow);
    try out.writeAll(if (status.api_usage_enabled) "api" else "local");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");

    try out.flush();
}

pub fn writeAutoSwitchLogLine(
    out: *std.Io.Writer,
    from: *const registry.AccountRecord,
    to: *const registry.AccountRecord,
) !void {
    try out.print("auto-switch: {s} -> {s}\n", .{ from.email, to.email });
    try out.flush();
}

fn emitAutoSwitchLog(from: *const registry.AccountRecord, to: *const registry.AccountRecord) void {
    var stderr_buffer: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&stderr_buffer);
    writeAutoSwitchLogLine(&writer.interface, from, to) catch {};
}

pub fn handleAutoCommand(allocator: std.mem.Allocator, codex_home: []const u8, cmd: cli.AutoOptions) !void {
    switch (cmd) {
        .action => |action| switch (action) {
            .enable => try enable(allocator, codex_home),
            .disable => try disable(allocator, codex_home),
        },
        .configure => |opts| try configureThresholds(allocator, codex_home, opts),
    }
}

pub fn handleApiUsageCommand(allocator: std.mem.Allocator, codex_home: []const u8, action: cli.ApiUsageAction) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const enabled = action == .enable;
    reg.api.usage = enabled;
    try registry.saveRegistry(allocator, codex_home, &reg);

    if (enabled) {
        var stderr_buffer: [512]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&stderr_buffer);
        const out = &writer.interface;
        try out.writeAll("\x1b[1;33mWarning:\x1b[0m Enabling API-based usage refresh may violate OpenAI's usage guidelines\n");
        try out.writeAll("         and lead to account suspension. Use at your own risk.\n");
        try out.flush();
    }
}

pub fn shouldEnsureManagedService(enabled: bool, runtime: RuntimeState, definition_matches: bool) bool {
    if (!enabled) return false;
    return runtime != .running or !definition_matches;
}

pub fn supportsManagedServiceOnPlatform(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn reconcileManagedService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    if (!supportsManagedServiceOnPlatform(builtin.os.tag)) return;

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (!reg.auto_switch.enabled) {
        try uninstallService(allocator, codex_home);
        return;
    }

    if (builtin.os.tag == .linux and !linuxUserSystemdAvailable(allocator)) return;

    const runtime = queryRuntimeState(allocator);
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const definition_matches = try currentServiceDefinitionMatches(allocator, codex_home, self_exe);
    if (!shouldEnsureManagedService(reg.auto_switch.enabled, runtime, definition_matches)) return;

    try installService(allocator, codex_home, self_exe);
}

pub fn runDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();

    while (true) {
        const keep_running = daemonCycle(allocator, codex_home) catch |err| blk: {
            std.log.err("auto daemon cycle failed: {s}", .{@errorName(err)});
            break :blk true;
        };
        if (!keep_running) return;
        std.Thread.sleep(poll_interval_ns);
    }
}

pub fn runDaemonOnce(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();

    _ = try daemonCycle(allocator, codex_home);
}

pub fn refreshActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return refreshActiveUsageWithApiFetcher(allocator, codex_home, reg, usage_api.fetchActiveUsage);
}

pub fn refreshActiveUsageWithApiFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !bool {
    if (reg.api.usage) {
        return switch (try refreshActiveUsageFromApi(allocator, codex_home, reg, api_fetcher)) {
            .updated => true,
            .unchanged, .unavailable => false,
        };
    }
    return refreshActiveUsageFromSessions(allocator, codex_home, reg);
}

const ApiRefreshResult = enum { unavailable, unchanged, updated };

fn refreshActiveUsageFromApi(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    api_fetcher: anytype,
) !ApiRefreshResult {
    const latest_usage = api_fetcher(allocator, codex_home) catch return .unavailable;
    if (latest_usage == null) return .unavailable;

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    const account_key = reg.active_account_key orelse return .unchanged;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .unchanged;
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, latest)) return .unchanged;

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    return .updated;
}

fn refreshActiveUsageFromSessions(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
) !bool {
    const latest_usage = sessions.scanLatestUsageWithSource(allocator, codex_home) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (latest_usage == null) return false;
    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer {
        allocator.free(latest.path);
        if (!snapshot_consumed) {
            registry.freeRateLimitSnapshot(allocator, &latest.snapshot);
        }
    }
    const signature: registry.RolloutSignature = .{
        .path = latest.path,
        .event_timestamp_ms = latest.event_timestamp_ms,
    };
    const account_key = reg.active_account_key orelse return false;
    const activated_at_ms = reg.active_account_activated_at_ms orelse 0;
    if (latest.event_timestamp_ms < activated_at_ms) return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    if (registry.rolloutSignaturesEqual(reg.accounts.items[idx].last_local_rollout, signature)) return false;
    registry.updateUsage(allocator, reg, account_key, latest.snapshot);
    snapshot_consumed = true;
    try registry.setAccountLastLocalRollout(allocator, &reg.accounts.items[idx], latest.path, latest.event_timestamp_ms);
    return true;
}

pub fn bestAutoSwitchCandidateIndex(reg: *registry.Registry, now: i64) ?usize {
    const active = reg.active_account_key orelse return null;
    var best_idx: ?usize = null;
    var best: ?CandidateScore = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        const score = candidateScore(rec, now);
        if (best == null or candidateBetter(score, best.?)) {
            best = score;
            best_idx = idx;
        }
    }
    return best_idx;
}

pub fn shouldSwitchCurrent(reg: *registry.Registry, now: i64) bool {
    const account_key = reg.active_account_key orelse return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    const rec = &reg.accounts.items[idx];
    const rem_5h = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 300, true), now);
    const rem_week = registry.remainingPercentAt(registry.resolveRateWindow(rec.last_usage, 10080, false), now);
    return (rem_5h != null and rem_5h.? < @as(i64, reg.auto_switch.threshold_5h_percent)) or
        (rem_week != null and rem_week.? < @as(i64, reg.auto_switch.threshold_weekly_percent));
}

pub fn maybeAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    if (!reg.auto_switch.enabled) return false;
    const active = reg.active_account_key orelse return false;
    const now = std.time.timestamp();
    if (!shouldSwitchCurrent(reg, now)) return false;

    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return false;
    const current = candidateScore(&reg.accounts.items[active_idx], now);
    const candidate_idx = bestAutoSwitchCandidateIndex(reg, now) orelse return false;
    const candidate = candidateScore(&reg.accounts.items[candidate_idx], now);
    if (candidate.value <= current.value) return false;

    try registry.activateAccountByKey(allocator, codex_home, reg, reg.accounts.items[candidate_idx].account_key);
    return true;
}

fn daemonCycle(allocator: std.mem.Allocator, codex_home: []const u8) !bool {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (!reg.auto_switch.enabled) return false;

    var changed = false;
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        changed = true;
    }

    var needs_refresh = false;
    for (reg.accounts.items) |rec| {
        if (rec.plan == null or rec.auth_mode == null) {
            needs_refresh = true;
            break;
        }
    }
    if (needs_refresh) {
        try registry.refreshAccountsFromAuth(allocator, codex_home, &reg);
        changed = true;
    }

    if (try refreshActiveUsage(allocator, codex_home, &reg)) {
        changed = true;
    }
    const active_idx_before = if (reg.active_account_key) |account_key|
        registry.findAccountIndexByAccountKey(&reg, account_key)
    else
        null;
    if (try maybeAutoSwitch(allocator, codex_home, &reg)) {
        changed = true;
        if (active_idx_before) |from_idx| {
            if (reg.active_account_key) |account_key| {
                if (registry.findAccountIndexByAccountKey(&reg, account_key)) |to_idx| {
                    emitAutoSwitchLog(&reg.accounts.items[from_idx], &reg.accounts.items[to_idx]);
                }
            }
        }
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    return true;
}

fn enable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    try enableWithServiceHooks(allocator, codex_home, self_exe, installService, uninstallService);
}

fn ensureAutoSwitchCanEnable(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux and !linuxUserSystemdAvailable(allocator)) {
        std.log.err("cannot enable auto-switch: systemd --user is unavailable", .{});
        return error.CommandFailed;
    }
}

pub fn enableWithServiceHooks(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
) !void {
    try enableWithServiceHooksAndPreflight(
        allocator,
        codex_home,
        self_exe,
        installer,
        uninstaller,
        ensureAutoSwitchCanEnable,
    );
}

pub fn enableWithServiceHooksAndPreflight(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    self_exe: []const u8,
    installer: anytype,
    uninstaller: anytype,
    preflight: anytype,
) !void {
    try preflight(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    reg.auto_switch.enabled = true;
    try registry.saveRegistry(allocator, codex_home, &reg);
    errdefer {
        reg.auto_switch.enabled = false;
        registry.saveRegistry(allocator, codex_home, &reg) catch {};
    }
    // Service installation can partially succeed on some platforms, so clean up
    // any managed artifacts before persisting the disabled rollback state.
    errdefer uninstaller(allocator, codex_home) catch {};
    try installer(allocator, codex_home, self_exe);
}

fn disable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.auto_switch.enabled = false;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try uninstallService(allocator, codex_home);
}

pub fn applyThresholdConfig(cfg: *registry.AutoSwitchConfig, opts: cli.AutoThresholdOptions) void {
    if (opts.threshold_5h_percent) |value| {
        cfg.threshold_5h_percent = value;
    }
    if (opts.threshold_weekly_percent) |value| {
        cfg.threshold_weekly_percent = value;
    }
}

fn configureThresholds(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.AutoThresholdOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    applyThresholdConfig(&reg.auto_switch, opts);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}

fn candidateScore(rec: *const registry.AccountRecord, now: i64) CandidateScore {
    const usage_score = registry.usageScoreAt(rec.last_usage, now) orelse 100;
    return .{
        .value = usage_score,
        .last_usage_at = rec.last_usage_at orelse -1,
        .created_at = rec.created_at,
    };
}

fn candidateBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.value != b.value) return a.value > b.value;
    if (a.last_usage_at != b.last_usage_at) return a.last_usage_at > b.last_usage_at;
    return a.created_at > b.created_at;
}

fn queryRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    return switch (builtin.os.tag) {
        .linux => queryLinuxRuntimeState(allocator),
        .macos => queryMacRuntimeState(allocator),
        .windows => queryWindowsRuntimeState(allocator),
        else => .unknown,
    };
}

fn installService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try installLinuxService(allocator, codex_home, self_exe),
        .macos => try installMacService(allocator, codex_home, self_exe),
        .windows => try installWindowsService(allocator, codex_home, self_exe),
        else => return error.UnsupportedPlatform,
    }
}

fn uninstallService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => try uninstallLinuxService(allocator, codex_home),
        .macos => try uninstallMacService(allocator, codex_home),
        .windows => try uninstallWindowsService(allocator),
        else => return error.UnsupportedPlatform,
    }
}

fn installLinuxService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const unit_text = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(unit_text);
    const timer_path = try linuxUnitPath(allocator, linux_timer_name);
    defer allocator.free(timer_path);
    const timer_text = try linuxTimerText(allocator);
    defer allocator.free(timer_text);

    const unit_dir = std.fs.path.dirname(unit_path).?;
    try std.fs.cwd().makePath(unit_dir);
    try std.fs.cwd().writeFile(.{ .sub_path = unit_path, .data = unit_text });
    try std.fs.cwd().writeFile(.{ .sub_path = timer_path, .data = timer_text });
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
    // Clean up the legacy long-running service enablement before switching to the timer model.
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", "--now", linux_service_name });
    try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "enable", linux_timer_name });
    switch (queryLinuxRuntimeState(allocator)) {
        .running => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "restart", linux_timer_name }),
        else => try runChecked(allocator, &[_][]const u8{ "systemctl", "--user", "start", linux_timer_name }),
    }
}

fn uninstallLinuxService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    try removeLinuxUnit(allocator, linux_timer_name);
    try removeLinuxUnit(allocator, linux_service_name);
}

fn removeLinuxUnit(allocator: std.mem.Allocator, service_name: []const u8) !void {
    const unit_path = try linuxUnitPath(allocator, service_name);
    defer allocator.free(unit_path);
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "disable", "--now", service_name });
    std.fs.cwd().deleteFile(unit_path) catch {};
    runIgnoringFailure(allocator, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });
}

fn linuxUserSystemdAvailable(allocator: std.mem.Allocator) bool {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "show-environment" }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn installMacService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const plist = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(plist);

    const dir = std.fs.path.dirname(plist_path).?;
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = plist_path, .data = plist });
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    try runChecked(allocator, &[_][]const u8{ "launchctl", "load", plist_path });
}

fn uninstallMacService(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    _ = codex_home;
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    _ = runChecked(allocator, &[_][]const u8{ "launchctl", "unload", plist_path }) catch {};
    std.fs.cwd().deleteFile(plist_path) catch {};
}

fn installWindowsService(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !void {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    try std.fs.cwd().access(helper_path, .{});

    const action = try windowsTaskAction(allocator, helper_path);
    defer allocator.free(action);
    const end_script = try windowsEndTaskScript(allocator);
    defer allocator.free(end_script);
    _ = runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        end_script,
    }) catch {};
    try runChecked(allocator, &[_][]const u8{
        "schtasks",
        "/Create",
        "/SC",
        "MINUTE",
        "/MO",
        "1",
        "/TN",
        windows_task_name,
        "/TR",
        action,
        "/F",
    });
    try runChecked(allocator, &[_][]const u8{
        "schtasks",
        "/Run",
        "/TN",
        windows_task_name,
    });
}

fn uninstallWindowsService(allocator: std.mem.Allocator) !void {
    const script = try windowsDeleteTaskScript(allocator);
    defer allocator.free(script);
    try runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    });
}

fn queryLinuxRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const result = runCapture(allocator, &[_][]const u8{ "systemctl", "--user", "is-active", linux_timer_name }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0 and std.mem.startsWith(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), "active")) .running else .stopped,
        else => .unknown,
    };
}

fn queryMacRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const plist_path = macPlistPath(allocator) catch return .unknown;
    defer allocator.free(plist_path);
    const result = runCapture(allocator, &[_][]const u8{ "launchctl", "list", mac_label }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) .running else .stopped,
        else => .unknown,
    };
}

fn queryWindowsRuntimeState(allocator: std.mem.Allocator) RuntimeState {
    const script = windowsTaskStateScript();
    const result = runCapture(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    }) catch return .unknown;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| if (code == 0) parseWindowsTaskStateOutput(result.stdout) else if (code == 1) .stopped else .unknown,
        else => .unknown,
    };
}

pub fn linuxUnitText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    _ = codex_home;
    const exec = try std.fmt.allocPrint(allocator, "\"{s}\" daemon --once", .{self_exe});
    defer allocator.free(exec);
    const escaped_version = try escapeSystemdValue(allocator, version.app_version);
    defer allocator.free(escaped_version);
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription=codex-auth auto-switch check\n\n[Service]\nType=oneshot\nEnvironment=\"{s}={s}\"\nExecStart={s}\n",
        .{ service_version_env_name, escaped_version, exec },
    );
}

pub fn linuxTimerText(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription=Run codex-auth auto-switch every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nUnit={s}\n\n[Install]\nWantedBy=timers.target\n",
        .{linux_service_name},
    );
}

pub fn macPlistText(allocator: std.mem.Allocator, self_exe: []const u8, codex_home: []const u8) ![]u8 {
    _ = codex_home;
    const exe = try escapeXml(allocator, self_exe);
    defer allocator.free(exe);
    const current_version = try escapeXml(allocator, version.app_version);
    defer allocator.free(current_version);
    return try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n  <key>Label</key>\n  <string>{s}</string>\n  <key>ProgramArguments</key>\n  <array>\n    <string>{s}</string>\n    <string>daemon</string>\n    <string>--watch</string>\n  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n    <key>{s}</key>\n    <string>{s}</string>\n  </dict>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n</dict>\n</plist>\n",
        .{ mac_label, exe, service_version_env_name, current_version },
    );
}

pub fn windowsTaskAction(allocator: std.mem.Allocator, helper_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "\"{s}\"", .{helper_path});
}

pub fn windowsTaskMatchScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; $action = $task.Actions | Select-Object -First 1; if ($null -eq $action) {{ exit 2 }}; $xml = [xml](Export-ScheduledTask -TaskName '{s}'); $triggers = @($xml.Task.Triggers.ChildNodes | Where-Object {{ $_.NodeType -eq [System.Xml.XmlNodeType]::Element }}); if ($triggers.Count -ne 1) {{ exit 3 }}; $interval = [string]$triggers[0].Repetition.Interval; if ([string]::IsNullOrWhiteSpace($interval)) {{ exit 4 }}; $args = if ([string]::IsNullOrWhiteSpace($action.Arguments)) {{ '' }} else {{ ' ' + $action.Arguments }}; Write-Output ($action.Execute + $args + '|TRIGGER:' + $interval)",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsEndTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; if ($task.State -eq 4) {{ Stop-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue }}",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsDeleteTaskScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 0 }}; Unregister-ScheduledTask -TaskName '{s}' -Confirm:$false",
        .{ windows_task_name, windows_task_name },
    );
}

pub fn windowsTaskStateScript() []const u8 {
    return "$task = Get-ScheduledTask -TaskName '" ++ windows_task_name ++ "' -ErrorAction SilentlyContinue; if ($null -eq $task) { exit 1 }; Write-Output ([int]$task.State)";
}

pub fn parseWindowsTaskStateOutput(output: []const u8) RuntimeState {
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return .unknown;
    const value = std.fmt.parseInt(u8, trimmed, 10) catch return .unknown;
    return switch (value) {
        2, 3, 4 => .running,
        0, 1 => .stopped,
        else => .unknown,
    };
}

fn linuxUnitPath(allocator: std.mem.Allocator, service_name: []const u8) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "systemd", "user", service_name });
}

fn currentServiceDefinitionMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    return switch (builtin.os.tag) {
        .linux => try linuxUnitMatches(allocator, codex_home, self_exe),
        .macos => try macPlistMatches(allocator, codex_home, self_exe),
        .windows => try windowsTaskMatches(allocator, codex_home, self_exe),
        else => true,
    };
}

fn linuxUnitMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const expected = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    if (!(try fileEqualsBytes(allocator, unit_path, expected))) return false;

    const timer_path = try linuxUnitPath(allocator, linux_timer_name);
    defer allocator.free(timer_path);
    const expected_timer = try linuxTimerText(allocator);
    defer allocator.free(expected_timer);
    return try fileEqualsBytes(allocator, timer_path, expected_timer);
}

fn macPlistMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    const plist_path = try macPlistPath(allocator);
    defer allocator.free(plist_path);
    const expected = try macPlistText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    return try fileEqualsBytes(allocator, plist_path, expected);
}

fn windowsTaskMatches(allocator: std.mem.Allocator, codex_home: []const u8, self_exe: []const u8) !bool {
    _ = codex_home;
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    const expected_fingerprint = try std.fmt.allocPrint(
        allocator,
        "{s}|TRIGGER:{s}",
        .{ helper_path, windows_task_trigger_interval },
    );
    defer allocator.free(expected_fingerprint);
    const script = try windowsTaskMatchScript(allocator);
    defer allocator.free(script);
    const result = runCapture(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        script,
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .Exited => |code| code == 0 and std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), expected_fingerprint),
        else => false,
    };
}

fn windowsHelperPath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_exe) orelse return error.FileNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ dir, windows_helper_name });
}

fn macPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try registry.resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "LaunchAgents", mac_label ++ ".plist" });
}

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try runCapture(allocator, argv);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
        },
        else => {},
    }
    if (result.stderr.len > 0) {
        std.log.err("{s}", .{std.mem.trim(u8, result.stderr, " \n\r\t")});
    }
    return error.CommandFailed;
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn fileEqualsBytes(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !bool {
    const data = try readFileIfExists(allocator, path);
    defer if (data) |buf| allocator.free(buf);
    if (data == null) return false;
    return std.mem.eql(u8, data.?, bytes);
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
}

fn runIgnoringFailure(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = runCapture(allocator, argv) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn escapeXml(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn escapeSystemdValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (raw) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, ch),
        }
    }
    return try out.toOwnedSlice(allocator);
}
