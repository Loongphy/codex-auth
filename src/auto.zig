const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const io_util = @import("io_util.zig");
const registry = @import("registry.zig");
const sessions = @import("sessions.zig");
const timefmt = @import("timefmt.zig");
const usage_api = @import("usage_api.zig");
const version = @import("version.zig");

const linux_service_name = "codex-auth-autoswitch.service";
const linux_timer_name = "codex-auth-autoswitch.timer";
const mac_label = "com.loongphy.codex-auth.auto";
const windows_task_name = "CodexAuthAutoSwitch";
const windows_helper_name = "codex-auth-auto.exe";
const lock_file_name = "auto-switch.lock";
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
    interval_seconds: u32,
    threshold_5h_percent: u8,
    threshold_weekly_percent: u8,
    api_usage_enabled: bool,
};

const service_version_env_name = "CODEX_AUTH_VERSION";

const CandidateTier = enum(u8) {
    ineligible = 0,
    fallback = 1,
    preferred = 2,
    unknown = 3,
};

const CandidateState = struct {
    tier: CandidateTier,
    remaining_5h: ?i64,
    remaining_weekly: ?i64,
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
        .interval_seconds = currentPlatformIntervalSeconds(reg.auto_switch.interval_seconds),
        .threshold_5h_percent = reg.auto_switch.threshold_5h_percent,
        .threshold_weekly_percent = reg.auto_switch.threshold_weekly_percent,
        .api_usage_enabled = reg.api.usage,
    };
}

pub fn writeStatus(out: *std.Io.Writer, status: Status) !void {
    try writeStatusWithColor(out, status, false);
}

fn writeStatusWithColor(out: *std.Io.Writer, status: Status, use_color: bool) !void {
    const interval_label = try timefmt.formatSimpleDurationAlloc(std.heap.page_allocator, status.interval_seconds);
    defer std.heap.page_allocator.free(interval_label);

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
    try out.writeAll("interval: ");
    if (use_color) try out.writeAll(ansi.yellow);
    try out.writeAll(interval_label);
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
        .configure => |opts| try configureAutoSwitch(allocator, codex_home, opts),
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
        std.Thread.sleep(daemonPollIntervalNs(allocator, codex_home));
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
    var best: ?CandidateState = null;
    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        const state = candidateState(rec, now, reg.auto_switch, reg.api.usage);
        if (!candidateRankEligible(state)) continue;
        if (best == null or candidateBetter(state, best.?)) {
            best = state;
            best_idx = idx;
        }
    }
    return best_idx;
}

pub fn shouldSwitchCurrent(reg: *registry.Registry, now: i64) bool {
    const account_key = reg.active_account_key orelse return false;
    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return false;
    const rec = &reg.accounts.items[idx];
    const rem_5h = registry.remainingPercentAt(resolveExactRateWindow(rec.last_usage, 300), now);
    const rem_week = registry.remainingPercentAt(resolveExactRateWindow(rec.last_usage, 10080), now);
    return shouldSwitchWithRemaining(registry.resolvePlan(rec), rem_5h, rem_week, reg.auto_switch);
}

pub fn maybeAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, reg: *registry.Registry) !bool {
    return maybeAutoSwitchWithCandidateUsageFetcher(allocator, codex_home, reg, usage_api.fetchUsageForAuthPath);
}

pub fn maybeAutoSwitchWithCandidateUsageFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    candidate_usage_fetcher: anytype,
) !bool {
    if (!reg.auto_switch.enabled) return false;
    const active = reg.active_account_key orelse return false;
    const now = std.time.timestamp();
    if (!shouldSwitchCurrent(reg, now)) return false;

    const active_idx = registry.findAccountIndexByAccountKey(reg, active) orelse return false;
    const current = candidateState(&reg.accounts.items[active_idx], now, reg.auto_switch, false);

    var candidate_indices = try rankedAutoSwitchCandidateIndices(allocator, reg, now);
    defer candidate_indices.deinit(allocator);

    for (candidate_indices.items) |candidate_idx| {
        if (reg.api.usage) {
            const refreshed = try refreshCandidateUsageWithFetcher(
                allocator,
                codex_home,
                reg,
                reg.accounts.items[candidate_idx].account_key,
                candidate_usage_fetcher,
            );
            if (refreshed == .unavailable) continue;
        }

        const candidate = candidateState(&reg.accounts.items[candidate_idx], now, reg.auto_switch, false);
        if (!candidateSwitchEligible(candidate)) continue;
        if (!candidateBetter(candidate, current)) continue;

        try registry.activateAccountByKey(allocator, codex_home, reg, reg.accounts.items[candidate_idx].account_key);
        return true;
    }

    return false;
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

pub fn applyAutoConfig(cfg: *registry.AutoSwitchConfig, opts: cli.AutoConfigOptions) void {
    if (opts.threshold_5h_percent) |value| {
        cfg.threshold_5h_percent = value;
    }
    if (opts.threshold_weekly_percent) |value| {
        cfg.threshold_weekly_percent = value;
    }
    if (opts.interval_seconds) |value| {
        cfg.interval_seconds = value;
    }
}

fn configureAutoSwitch(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.AutoConfigOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const requested_interval_seconds = opts.interval_seconds;
    applyAutoConfig(&reg.auto_switch, opts);
    if (requested_interval_seconds) |requested| {
        const effective = currentPlatformIntervalSeconds(requested);
        if (builtin.os.tag == .windows and effective != requested) {
            reg.auto_switch.interval_seconds = effective;
            try printWindowsIntervalClampWarning(requested, effective);
        }
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}

fn currentPlatformIntervalSeconds(interval_seconds: u32) u32 {
    return registry.effectiveAutoSwitchIntervalSeconds(interval_seconds, builtin.os.tag);
}

fn daemonPollIntervalNs(allocator: std.mem.Allocator, codex_home: []const u8) u64 {
    const interval_seconds = loadConfiguredIntervalSeconds(allocator, codex_home) catch registry.default_auto_switch_interval_seconds;
    return @as(u64, interval_seconds) * std.time.ns_per_s;
}

fn loadConfiguredIntervalSeconds(allocator: std.mem.Allocator, codex_home: []const u8) !u32 {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    return currentPlatformIntervalSeconds(reg.auto_switch.interval_seconds);
}

fn printWindowsIntervalClampWarning(requested_seconds: u32, effective_seconds: u32) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try writeWindowsIntervalClampWarning(&writer.interface, requested_seconds, effective_seconds);
    try writer.interface.flush();
}

pub fn writeWindowsIntervalClampWarning(out: *std.Io.Writer, requested_seconds: u32, effective_seconds: u32) !void {
    const requested_label = try timefmt.formatSimpleDurationAlloc(std.heap.page_allocator, requested_seconds);
    defer std.heap.page_allocator.free(requested_label);
    const effective_label = try timefmt.formatSimpleDurationAlloc(std.heap.page_allocator, effective_seconds);
    defer std.heap.page_allocator.free(effective_label);

    try out.print(
        "Warning: Windows Task Scheduler does not support intervals below 1 minute; saved auto-switch interval as {s} instead of {s}.\n",
        .{ effective_label, requested_label },
    );
}

fn rankedAutoSwitchCandidateIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    now: i64,
) !std.ArrayList(usize) {
    const active = reg.active_account_key orelse return std.ArrayList(usize).empty;
    var indices = std.ArrayList(usize).empty;
    errdefer indices.deinit(allocator);

    for (reg.accounts.items, 0..) |*rec, idx| {
        if (std.mem.eql(u8, rec.account_key, active)) continue;
        const state = candidateState(rec, now, reg.auto_switch, reg.api.usage);
        if (!candidateRankEligible(state)) continue;
        try indices.append(allocator, idx);
    }

    std.sort.insertion(usize, indices.items, CandidateSortContext{ .reg = reg, .now = now }, lessThanCandidateIndex);
    return indices;
}

const CandidateSortContext = struct {
    reg: *registry.Registry,
    now: i64,
};

fn lessThanCandidateIndex(ctx: CandidateSortContext, lhs: usize, rhs: usize) bool {
    const reg = ctx.reg;
    const left = candidateState(&reg.accounts.items[lhs], ctx.now, reg.auto_switch, reg.api.usage);
    const right = candidateState(&reg.accounts.items[rhs], ctx.now, reg.auto_switch, reg.api.usage);
    return candidateBetter(left, right);
}

fn candidateState(
    rec: *const registry.AccountRecord,
    now: i64,
    cfg: registry.AutoSwitchConfig,
    allow_revalidation: bool,
) CandidateState {
    const remaining_5h = registry.remainingPercentAt(resolveExactRateWindow(rec.last_usage, 300), now);
    const remaining_weekly = registry.remainingPercentAt(resolveExactRateWindow(rec.last_usage, 10080), now);
    const tier = determineCandidateTier(remaining_5h, remaining_weekly, registry.resolvePlan(rec), cfg, allow_revalidation);
    return .{
        .tier = tier,
        .remaining_5h = remaining_5h,
        .remaining_weekly = remaining_weekly,
        .last_usage_at = rec.last_usage_at orelse -1,
        .created_at = rec.created_at,
    };
}

fn resolveExactRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |primary| {
        if (primary.window_minutes != null and primary.window_minutes.? == minutes) return primary;
    }
    if (usage.?.secondary) |secondary| {
        if (secondary.window_minutes != null and secondary.window_minutes.? == minutes) return secondary;
    }
    return null;
}

fn singleWindowRemaining(remaining_5h: ?i64, remaining_weekly: ?i64) ?i64 {
    return remaining_5h orelse remaining_weekly;
}

fn usesSingleWindowFreeMode(plan: ?registry.PlanType, remaining_5h: ?i64, remaining_weekly: ?i64) bool {
    return plan == .free and ((remaining_5h == null) != (remaining_weekly == null));
}

fn shouldSwitchWithRemaining(
    plan: ?registry.PlanType,
    remaining_5h: ?i64,
    remaining_weekly: ?i64,
    cfg: registry.AutoSwitchConfig,
) bool {
    if (usesSingleWindowFreeMode(plan, remaining_5h, remaining_weekly)) {
        const remaining = singleWindowRemaining(remaining_5h, remaining_weekly) orelse return false;
        return remaining < @as(i64, cfg.threshold_5h_percent);
    }
    const rem_5h = remaining_5h orelse return false;
    const rem_weekly = remaining_weekly orelse return false;
    return rem_5h < @as(i64, cfg.threshold_5h_percent) or rem_weekly < @as(i64, cfg.threshold_weekly_percent);
}

fn determineCandidateTier(
    remaining_5h: ?i64,
    remaining_weekly: ?i64,
    plan: ?registry.PlanType,
    cfg: registry.AutoSwitchConfig,
    allow_revalidation: bool,
) CandidateTier {
    if (usesSingleWindowFreeMode(plan, remaining_5h, remaining_weekly)) {
        const remaining = singleWindowRemaining(remaining_5h, remaining_weekly) orelse return if (allow_revalidation) .unknown else .ineligible;
        if (remaining <= 0) return .ineligible;
        if (remaining > @as(i64, cfg.threshold_5h_percent)) return .preferred;
        return .fallback;
    }
    const rem_5h = remaining_5h orelse return if (allow_revalidation) .unknown else .ineligible;
    const rem_weekly = remaining_weekly orelse return if (allow_revalidation) .unknown else .ineligible;
    if (rem_5h <= 0 or rem_weekly <= 0) {
        return .ineligible;
    }
    if (rem_5h > @as(i64, cfg.threshold_5h_percent) and rem_weekly > @as(i64, cfg.threshold_weekly_percent)) {
        return .preferred;
    }
    return .fallback;
}

fn candidateRankEligible(candidate: CandidateState) bool {
    return candidate.tier != .ineligible;
}

fn candidateSwitchEligible(candidate: CandidateState) bool {
    return candidate.tier == .preferred or candidate.tier == .fallback;
}

fn candidatePrimaryRemaining(candidate: CandidateState) i64 {
    return candidate.remaining_5h orelse candidate.remaining_weekly orelse -1;
}

fn candidateBetter(a: CandidateState, b: CandidateState) bool {
    if (@intFromEnum(a.tier) != @intFromEnum(b.tier)) return @intFromEnum(a.tier) > @intFromEnum(b.tier);

    if (candidateSwitchEligible(a) and candidateSwitchEligible(b)) {
        const a_5h = candidatePrimaryRemaining(a);
        const b_5h = candidatePrimaryRemaining(b);
        if (a_5h != b_5h) return a_5h > b_5h;
        const a_weekly = a.remaining_weekly orelse a.remaining_5h orelse -1;
        const b_weekly = b.remaining_weekly orelse b.remaining_5h orelse -1;
        if (a_weekly != b_weekly) return a_weekly > b_weekly;
    }

    if (a.last_usage_at != b.last_usage_at) return a.last_usage_at > b.last_usage_at;
    return a.created_at > b.created_at;
}

const CandidateRefreshResult = enum { unavailable, unchanged, updated };

fn refreshCandidateUsageWithFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    account_key: []const u8,
    candidate_usage_fetcher: anytype,
) !CandidateRefreshResult {
    const auth_path = registry.accountAuthPath(allocator, codex_home, account_key) catch return .unavailable;
    defer allocator.free(auth_path);

    const latest_usage = candidate_usage_fetcher(allocator, auth_path) catch return .unavailable;
    if (latest_usage == null) return .unavailable;

    var latest = latest_usage.?;
    var snapshot_consumed = false;
    defer if (!snapshot_consumed) registry.freeRateLimitSnapshot(allocator, &latest);

    const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse return .unavailable;
    if (registry.rateLimitSnapshotsEqual(reg.accounts.items[idx].last_usage, latest)) return .unchanged;

    registry.updateUsage(allocator, reg, account_key, latest);
    snapshot_consumed = true;
    return .updated;
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
    const interval_seconds = try loadConfiguredIntervalSeconds(allocator, codex_home);
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const unit_text = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(unit_text);
    const timer_path = try linuxUnitPath(allocator, linux_timer_name);
    defer allocator.free(timer_path);
    const timer_text = try linuxTimerText(allocator, interval_seconds);
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
    const interval_seconds = try loadConfiguredIntervalSeconds(allocator, codex_home);
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    try std.fs.cwd().access(helper_path, .{});

    const create_script = try windowsCreateTaskScript(allocator, helper_path, interval_seconds);
    defer allocator.free(create_script);
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
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        create_script,
    });
    try runChecked(allocator, &[_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-Command",
        "Start-ScheduledTask -TaskName '" ++ windows_task_name ++ "'",
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

pub fn linuxTimerText(allocator: std.mem.Allocator, interval_seconds: u32) ![]u8 {
    const interval_label = try formatSystemdIntervalAlloc(allocator, interval_seconds);
    defer allocator.free(interval_label);
    return try std.fmt.allocPrint(
        allocator,
        "[Unit]\nDescription=Run codex-auth auto-switch every {s}\n\n[Timer]\nOnBootSec={s}\nOnUnitActiveSec={s}\nUnit={s}\n\n[Install]\nWantedBy=timers.target\n",
        .{ interval_label, interval_label, interval_label, linux_service_name },
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

fn formatWindowsTaskIntervalAlloc(allocator: std.mem.Allocator, interval_seconds: u32) ![]u8 {
    return try std.fmt.allocPrint(allocator, "PT{d}S", .{interval_seconds});
}

pub fn windowsTaskXmlText(allocator: std.mem.Allocator, helper_path: []const u8, interval_seconds: u32) ![]u8 {
    const escaped_helper_path = try escapeXml(allocator, helper_path);
    defer allocator.free(escaped_helper_path);
    const interval = try formatWindowsTaskIntervalAlloc(allocator, interval_seconds);
    defer allocator.free(interval);
    return try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<Task version=\"1.4\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n  <Triggers>\n    <TimeTrigger>\n      <Repetition>\n        <Interval>{s}</Interval>\n      </Repetition>\n      <StartBoundary>2000-01-01T00:00:00</StartBoundary>\n      <Enabled>true</Enabled>\n    </TimeTrigger>\n  </Triggers>\n  <Principals>\n    <Principal id=\"Author\">\n      <LogonType>InteractiveToken</LogonType>\n      <RunLevel>LeastPrivilege</RunLevel>\n    </Principal>\n  </Principals>\n  <Settings>\n    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\n    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\n    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\n    <AllowHardTerminate>true</AllowHardTerminate>\n    <StartWhenAvailable>true</StartWhenAvailable>\n    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>\n    <IdleSettings>\n      <StopOnIdleEnd>false</StopOnIdleEnd>\n      <RestartOnIdle>false</RestartOnIdle>\n    </IdleSettings>\n    <AllowStartOnDemand>true</AllowStartOnDemand>\n    <Enabled>true</Enabled>\n    <Hidden>false</Hidden>\n    <RunOnlyIfIdle>false</RunOnlyIfIdle>\n    <WakeToRun>false</WakeToRun>\n    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\n    <Priority>7</Priority>\n  </Settings>\n  <Actions Context=\"Author\">\n    <Exec>\n      <Command>{s}</Command>\n    </Exec>\n  </Actions>\n</Task>\n",
        .{ interval, escaped_helper_path },
    );
}

pub fn windowsCreateTaskScript(allocator: std.mem.Allocator, helper_path: []const u8, interval_seconds: u32) ![]u8 {
    const xml = try windowsTaskXmlText(allocator, helper_path, interval_seconds);
    defer allocator.free(xml);
    return try std.fmt.allocPrint(
        allocator,
        "$xml = @'\n{s}'@\nRegister-ScheduledTask -TaskName '{s}' -Xml $xml -Force | Out-Null",
        .{ xml, windows_task_name },
    );
}

pub fn windowsTaskMatchScript(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "$task = Get-ScheduledTask -TaskName '{s}' -ErrorAction SilentlyContinue; if ($null -eq $task) {{ exit 1 }}; $action = $task.Actions | Select-Object -First 1; if ($null -eq $action) {{ exit 2 }}; $xml = [xml](Export-ScheduledTask -TaskName '{s}'); $triggers = @($xml.Task.Triggers.ChildNodes | Where-Object {{ $_.NodeType -eq [System.Xml.XmlNodeType]::Element }}); if ($triggers.Count -ne 1) {{ exit 3 }}; $interval = [string]$triggers[0].Repetition.Interval; if ([string]::IsNullOrWhiteSpace($interval)) {{ exit 4 }}; $seconds = [int][System.Xml.XmlConvert]::ToTimeSpan($interval).TotalSeconds; $args = if ([string]::IsNullOrWhiteSpace($action.Arguments)) {{ '' }} else {{ ' ' + $action.Arguments }}; Write-Output ($action.Execute + $args + '|TRIGGER_SECONDS:' + $seconds)",
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
    const interval_seconds = try loadConfiguredIntervalSeconds(allocator, codex_home);
    const unit_path = try linuxUnitPath(allocator, linux_service_name);
    defer allocator.free(unit_path);
    const expected = try linuxUnitText(allocator, self_exe, codex_home);
    defer allocator.free(expected);
    if (!(try fileEqualsBytes(allocator, unit_path, expected))) return false;

    const timer_path = try linuxUnitPath(allocator, linux_timer_name);
    defer allocator.free(timer_path);
    const expected_timer = try linuxTimerText(allocator, interval_seconds);
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
    const interval_seconds = try loadConfiguredIntervalSeconds(allocator, codex_home);
    const helper_path = try windowsHelperPath(allocator, self_exe);
    defer allocator.free(helper_path);
    const expected_fingerprint = try std.fmt.allocPrint(
        allocator,
        "{s}|TRIGGER_SECONDS:{d}",
        .{ helper_path, interval_seconds },
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

fn formatSystemdIntervalAlloc(allocator: std.mem.Allocator, interval_seconds: u32) ![]u8 {
    if (interval_seconds != 0 and @mod(interval_seconds, 60 * 60) == 0) {
        return std.fmt.allocPrint(allocator, "{d}h", .{@divTrunc(interval_seconds, 60 * 60)});
    }
    if (interval_seconds != 0 and @mod(interval_seconds, 60) == 0) {
        return std.fmt.allocPrint(allocator, "{d}min", .{@divTrunc(interval_seconds, 60)});
    }
    return std.fmt.allocPrint(allocator, "{d}s", .{interval_seconds});
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
