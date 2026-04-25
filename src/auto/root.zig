const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const account_api = @import("../api/account.zig");
const account_name_refresh = @import("../auth/account.zig");
const auth = @import("../auth/auth.zig");
const builtin = @import("builtin");
const c_time = @cImport({
    @cInclude("time.h");
});
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");
const sessions = @import("../session.zig");
const terminal_color = @import("../terminal/color.zig");
const usage_api = @import("../api/usage.zig");
const service = @import("service.zig");

pub const RuntimeState = service.RuntimeState;
const queryRuntimeState = service.queryRuntimeState;
const installService = service.installService;
const uninstallService = service.uninstallService;
const linuxUserSystemdAvailable = service.linuxUserSystemdAvailable;
pub const managedServiceSelfExePath = service.managedServiceSelfExePath;
const currentServiceDefinitionMatches = service.currentServiceDefinitionMatches;
pub const deleteAbsoluteFileIfExists = service.deleteAbsoluteFileIfExists;
pub const linuxUnitText = service.linuxUnitText;
pub const macPlistText = service.macPlistText;
pub const windowsTaskAction = service.windowsTaskAction;
pub const windowsRegisterTaskScript = service.windowsRegisterTaskScript;
pub const windowsTaskMatchScript = service.windowsTaskMatchScript;
pub const windowsEndTaskScript = service.windowsEndTaskScript;
pub const windowsDeleteTaskScript = service.windowsDeleteTaskScript;
pub const windowsTaskStateScript = service.windowsTaskStateScript;
pub const parseWindowsTaskStateOutput = service.parseWindowsTaskStateOutput;
pub const managedServiceSelfExePathFromDir = service.managedServiceSelfExePathFromDir;

const candidate_mod = @import("candidate.zig");
const status_mod = @import("status.zig");
const logging = @import("logging.zig");
const files = @import("files.zig");
const state = @import("state.zig");
const usage_refresh = @import("usage_refresh.zig");
const switching = @import("switching.zig");

pub const Status = status_mod.Status;
pub const CandidateScore = candidate_mod.CandidateScore;
pub const CandidateEntry = candidate_mod.CandidateEntry;
pub const CandidateIndex = candidate_mod.CandidateIndex;
pub const DaemonRefreshState = state.DaemonRefreshState;
const api_refresh_interval_ns = state.api_refresh_interval_ns;
const candidate_switch_validation_limit = candidate_mod.candidate_switch_validation_limit;
const candidateScore = candidate_mod.candidateScore;
const candidateBetter = candidate_mod.candidateBetter;

pub const helpStateLabel = status_mod.helpStateLabel;
pub const printStatus = status_mod.printStatus;
pub const getStatus = status_mod.getStatus;
pub const writeStatus = status_mod.writeStatus;

pub const writeAutoSwitchLogLine = logging.writeAutoSwitchLogLine;
const emitAutoSwitchLog = logging.emitAutoSwitchLog;
const emitDaemonLog = logging.emitDaemonLog;
const emitTaggedDaemonLog = logging.emitTaggedDaemonLog;
const localDateTimeLabel = logging.localDateTimeLabel;
const rolloutFileLabel = logging.rolloutFileLabel;
const rolloutWindowsLabel = logging.rolloutWindowsLabel;
const apiStatusLabel = logging.apiStatusLabel;
const fieldSeparator = logging.fieldSeparator;
const fileMtimeNsIfExists = files.fileMtimeNsIfExists;
pub const refreshActiveUsage = usage_refresh.refreshActiveUsage;
const fetchActiveAccountNames = usage_refresh.fetchActiveAccountNames;
pub const refreshActiveAccountNamesForDaemonWithFetcher = usage_refresh.refreshActiveAccountNamesForDaemonWithFetcher;
const refreshActiveUsageForDaemon = usage_refresh.refreshActiveUsageForDaemon;
pub const refreshActiveUsageForDaemonWithApiFetcher = usage_refresh.refreshActiveUsageForDaemonWithApiFetcher;
pub const refreshActiveUsageWithApiFetcher = usage_refresh.refreshActiveUsageWithApiFetcher;

pub const AutoSwitchAttempt = switching.AutoSwitchAttempt;
pub const bestAutoSwitchCandidateIndex = switching.bestAutoSwitchCandidateIndex;
pub const shouldSwitchCurrent = switching.shouldSwitchCurrent;
pub const maybeAutoSwitch = switching.maybeAutoSwitch;
pub const maybeAutoSwitchWithUsageFetcher = switching.maybeAutoSwitchWithUsageFetcher;
pub const maybeAutoSwitchForDaemonWithUsageFetcher = switching.maybeAutoSwitchForDaemonWithUsageFetcher;

const lock_file_name = "auto-switch.lock";
const watch_poll_interval_ns = 1 * std.time.ns_per_s;
const DaemonLock = struct {
    file: std.Io.File,

    fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?DaemonLock {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", lock_file_name });
        defer allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(app_runtime.io(), path, .{ .read = true, .truncate = false });
        errdefer file.close(app_runtime.io());
        if (!(try tryExclusiveLock(file))) {
            file.close(app_runtime.io());
            return null;
        }
        return .{ .file = file };
    }

    fn release(self: *DaemonLock) void {
        self.file.unlock(app_runtime.io());
        self.file.close(app_runtime.io());
    }
};

fn tryExclusiveLock(file: std.Io.File) !bool {
    return try file.tryLock(app_runtime.io(), .exclusive);
}

pub fn handleAutoCommand(allocator: std.mem.Allocator, codex_home: []const u8, cmd: cli.types.AutoOptions) !void {
    switch (cmd) {
        .action => |action| switch (action) {
            .enable => try enable(allocator, codex_home),
            .disable => try disable(allocator, codex_home),
        },
        .configure => |opts| try configureThresholds(allocator, codex_home, opts),
    }
}

pub fn handleApiCommand(allocator: std.mem.Allocator, codex_home: []const u8, action: cli.types.ApiAction) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const enabled = action == .enable;
    reg.api.usage = enabled;
    reg.api.account = enabled;
    try registry.saveRegistry(allocator, codex_home, &reg);
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
    const self_exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    const definition_matches = try currentServiceDefinitionMatches(allocator, codex_home, managed_self_exe);
    if (!shouldEnsureManagedService(reg.auto_switch.enabled, runtime, definition_matches)) return;

    try installService(allocator, codex_home, managed_self_exe);
}

pub fn runDaemon(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();
    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);

    while (true) {
        const keep_running = daemonCycle(allocator, codex_home, &refresh_state) catch |err| blk: {
            std.log.err("auto daemon cycle failed: {s}", .{@errorName(err)});
            break :blk true;
        };
        if (!keep_running) return;
        try std.Io.sleep(app_runtime.io(), .fromNanoseconds(watch_poll_interval_ns), .awake);
    }
}

pub fn runDaemonOnce(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    try registry.ensureAccountsDir(allocator, codex_home);
    var daemon_lock = (try DaemonLock.acquire(allocator, codex_home)) orelse return;
    defer daemon_lock.release();

    var refresh_state = DaemonRefreshState{};
    defer refresh_state.deinit(allocator);
    _ = try daemonCycle(allocator, codex_home, &refresh_state);
}

fn daemonCycleWithAccountNameFetcher(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    var reg = try refresh_state.ensureRegistryLoaded(allocator, codex_home);
    if (!reg.auto_switch.enabled) return false;

    var changed = false;
    if (try refresh_state.syncActiveAuthIfChanged(allocator, codex_home)) {
        changed = true;
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
        changed = false;
    }

    if (try refreshActiveAccountNamesForDaemonWithFetcher(allocator, codex_home, reg, refresh_state, account_name_fetcher)) {
        changed = true;
    }
    try refresh_state.reloadRegistryStateIfChanged(allocator, codex_home);
    reg = refresh_state.currentRegistry();
    if (!reg.auto_switch.enabled) return true;

    if (try refreshActiveUsageForDaemon(allocator, codex_home, reg, refresh_state)) {
        changed = true;
    }
    const active_idx_before = if (reg.active_account_key) |account_key|
        registry.findAccountIndexByAccountKey(reg, account_key)
    else
        null;
    const auto_switch_attempt = try maybeAutoSwitchForDaemonWithUsageFetcher(allocator, codex_home, reg, refresh_state, usage_api.fetchUsageForAuthPathDetailed);
    if (auto_switch_attempt.state_changed or auto_switch_attempt.switched) {
        changed = true;
    }
    if (auto_switch_attempt.switched) {
        if (active_idx_before) |from_idx| {
            if (reg.active_account_key) |account_key| {
                if (registry.findAccountIndexByAccountKey(reg, account_key)) |to_idx| {
                    emitAutoSwitchLog(&reg.accounts.items[from_idx], &reg.accounts.items[to_idx]);
                }
            }
        }
    }

    if (changed) {
        try registry.saveRegistry(allocator, codex_home, reg);
        try refresh_state.refreshTrackedFileMtims(allocator, codex_home);
    }
    return true;
}

fn daemonCycle(allocator: std.mem.Allocator, codex_home: []const u8, refresh_state: *DaemonRefreshState) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, fetchActiveAccountNames);
}

pub fn daemonCycleWithAccountNameFetcherForTest(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    refresh_state: *DaemonRefreshState,
    account_name_fetcher: anytype,
) !bool {
    return daemonCycleWithAccountNameFetcher(allocator, codex_home, refresh_state, account_name_fetcher);
}

fn enable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    const self_exe = try std.process.executablePathAlloc(app_runtime.io(), allocator);
    defer allocator.free(self_exe);
    const managed_self_exe = try managedServiceSelfExePath(allocator, self_exe);
    defer allocator.free(managed_self_exe);
    try enableWithServiceHooks(allocator, codex_home, managed_self_exe, installService, uninstallService);
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
    printAutoEnableUsageNote(reg.api.usage) catch |err| {
        std.log.warn("failed to print auto-enable usage note: {}", .{err});
    };
}

fn printAutoEnableUsageNote(api_enabled: bool) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (api_enabled) {
        try out.writeAll("auto-switch enabled; usage mode: api (default, most accurate for switching decisions)\n");
    } else {
        try out.writeAll("auto-switch enabled; usage mode: local-only (switching still works, but candidate validation is less accurate)\n");
        try out.writeAll("Tip: run `codex-auth config api enable` for the most accurate switching decisions.\n");
    }
    try out.flush();
}

fn disable(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    reg.auto_switch.enabled = false;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try uninstallService(allocator, codex_home);
}

pub fn applyThresholdConfig(cfg: *registry.AutoSwitchConfig, opts: cli.types.AutoThresholdOptions) void {
    if (opts.threshold_5h_percent) |value| {
        cfg.threshold_5h_percent = value;
    }
    if (opts.threshold_weekly_percent) |value| {
        cfg.threshold_weekly_percent = value;
    }
}

fn configureThresholds(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.AutoThresholdOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    applyThresholdConfig(&reg.auto_switch, opts);
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printStatus(allocator, codex_home);
}
