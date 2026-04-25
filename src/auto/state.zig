const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const sessions = @import("../session.zig");
const candidate = @import("candidate.zig");
const files = @import("files.zig");

const fileMtimeNsIfExists = files.fileMtimeNsIfExists;

pub const api_refresh_interval_ns = 60 * std.time.ns_per_s;

pub const DaemonRefreshState = struct {
    last_api_refresh_at_ns: i128 = 0,
    last_api_refresh_account_key: ?[]u8 = null,
    last_account_name_refresh_at_ns: i128 = 0,
    last_account_name_refresh_account_key: ?[]u8 = null,
    pending_bad_account_key: ?[]u8 = null,
    pending_bad_rollout: ?registry.RolloutSignature = null,
    current_reg: ?registry.Registry = null,
    registry_mtime_ns: i128 = 0,
    auth_mtime_ns: i128 = 0,
    candidate_index: candidate.CandidateIndex = .{},
    candidate_check_times: std.StringHashMapUnmanaged(i128) = .empty,
    candidate_rejections: std.StringHashMapUnmanaged(bool) = .empty,
    rollout_scan_cache: sessions.RolloutScanCache = .{},

    pub fn deinit(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        self.clearApiRefresh(allocator);
        self.clearAccountNameRefresh(allocator);
        self.clearPending(allocator);
        if (self.current_reg) |*reg| {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
            reg.deinit(allocator);
            self.current_reg = null;
        } else {
            self.candidate_index.deinit(allocator);
            self.candidate_check_times.deinit(allocator);
            self.candidate_rejections.deinit(allocator);
        }
        self.rollout_scan_cache.deinit(allocator);
    }

    pub fn clearApiRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_api_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_api_refresh_account_key = null;
        self.last_api_refresh_at_ns = 0;
    }

    pub fn clearAccountNameRefresh(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            allocator.free(account_key);
        }
        self.last_account_name_refresh_account_key = null;
        self.last_account_name_refresh_at_ns = 0;
    }

    pub fn clearPending(self: *DaemonRefreshState, allocator: std.mem.Allocator) void {
        if (self.pending_bad_account_key) |account_key| {
            allocator.free(account_key);
        }
        if (self.pending_bad_rollout) |*signature| {
            registry.freeRolloutSignature(allocator, signature);
        }
        self.pending_bad_account_key = null;
        self.pending_bad_rollout = null;
    }

    pub fn clearPendingIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: ?[]const u8,
    ) void {
        if (self.pending_bad_account_key == null) return;
        if (active_account_key) |account_key| {
            if (std.mem.eql(u8, self.pending_bad_account_key.?, account_key)) return;
        }
        self.clearPending(allocator);
    }

    pub fn pendingMatches(self: *const DaemonRefreshState, account_key: []const u8, signature: registry.RolloutSignature) bool {
        if (self.pending_bad_account_key == null or self.pending_bad_rollout == null) return false;
        return std.mem.eql(u8, self.pending_bad_account_key.?, account_key) and
            registry.rolloutSignaturesEqual(self.pending_bad_rollout, signature);
    }

    pub fn setPending(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        account_key: []const u8,
        signature: registry.RolloutSignature,
    ) !void {
        if (self.pendingMatches(account_key, signature)) return;
        self.clearPending(allocator);
        self.pending_bad_account_key = try allocator.dupe(u8, account_key);
        errdefer {
            allocator.free(self.pending_bad_account_key.?);
            self.pending_bad_account_key = null;
        }
        self.pending_bad_rollout = try registry.cloneRolloutSignature(allocator, signature);
    }

    pub fn resetApiCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_api_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearApiRefresh(allocator);
        self.last_api_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    pub fn resetAccountNameCooldownIfAccountChanged(
        self: *DaemonRefreshState,
        allocator: std.mem.Allocator,
        active_account_key: []const u8,
    ) !void {
        if (self.last_account_name_refresh_account_key) |account_key| {
            if (std.mem.eql(u8, account_key, active_account_key)) return;
        }
        self.clearAccountNameRefresh(allocator);
        self.last_account_name_refresh_account_key = try allocator.dupe(u8, active_account_key);
    }

    pub fn currentRegistry(self: *DaemonRefreshState) *registry.Registry {
        return &self.current_reg.?;
    }

    pub fn ensureRegistryLoaded(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !*registry.Registry {
        if (self.current_reg == null) {
            try self.reloadRegistryState(allocator, codex_home);
            // Force the first daemon cycle to sync auth.json into accounts/ snapshots
            // before grouped account-name refresh looks for stored auth contexts.
            self.auth_mtime_ns = -1;
        } else {
            try self.reloadRegistryStateIfChanged(allocator, codex_home);
        }
        return self.currentRegistry();
    }

    pub fn reloadRegistryStateIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        const current_mtime = (try fileMtimeNsIfExists(registry_path)) orelse 0;
        if (self.current_reg == null or current_mtime != self.registry_mtime_ns) {
            try self.reloadRegistryState(allocator, codex_home);
        }
    }

    pub fn reloadRegistryState(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        var loaded = try registry.loadRegistry(allocator, codex_home);
        errdefer loaded.deinit(allocator);

        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        if (self.current_reg) |*reg| {
            reg.deinit(allocator);
        }
        self.current_reg = loaded;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds());
        try self.refreshTrackedFileMtims(allocator, codex_home);
    }

    pub fn rebuildCandidateState(self: *DaemonRefreshState, allocator: std.mem.Allocator) !void {
        if (self.current_reg == null) return;
        self.candidate_index.deinit(allocator);
        self.candidate_check_times.deinit(allocator);
        self.candidate_check_times = .empty;
        self.candidate_rejections.deinit(allocator);
        self.candidate_rejections = .empty;
        try self.candidate_index.rebuild(allocator, &self.current_reg.?, std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds());
    }

    pub fn refreshTrackedFileMtims(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !void {
        const registry_path = try registry.registryPath(allocator, codex_home);
        defer allocator.free(registry_path);
        self.registry_mtime_ns = (try fileMtimeNsIfExists(registry_path)) orelse 0;

        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        self.auth_mtime_ns = (try fileMtimeNsIfExists(auth_path)) orelse 0;
    }

    pub fn syncActiveAuthIfChanged(self: *DaemonRefreshState, allocator: std.mem.Allocator, codex_home: []const u8) !bool {
        const auth_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(auth_path);
        const current_auth_mtime = (try fileMtimeNsIfExists(auth_path)) orelse 0;
        if (self.current_reg != null and current_auth_mtime == self.auth_mtime_ns) return false;
        self.auth_mtime_ns = current_auth_mtime;
        if (self.current_reg == null) return false;
        if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &self.current_reg.?)) {
            try self.rebuildCandidateState(allocator);
            return true;
        }
        return false;
    }

    pub fn markCandidateChecked(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8, now_ns: i128) !void {
        try self.candidate_check_times.put(allocator, account_key, now_ns);
    }

    pub fn candidateCheckedAt(self: *const DaemonRefreshState, account_key: []const u8) ?i128 {
        return self.candidate_check_times.get(account_key);
    }

    pub fn clearCandidateChecked(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_check_times.remove(account_key);
    }

    pub fn markCandidateRejected(self: *DaemonRefreshState, allocator: std.mem.Allocator, account_key: []const u8) !void {
        try self.candidate_rejections.put(allocator, account_key, true);
    }

    pub fn clearCandidateRejected(self: *DaemonRefreshState, account_key: []const u8) void {
        _ = self.candidate_rejections.remove(account_key);
    }

    pub fn candidateIsRejected(self: *DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        if (!self.candidate_rejections.contains(account_key)) return false;
        if (self.candidateIsStale(account_key, now_ns)) {
            self.clearCandidateRejected(account_key);
            return false;
        }
        return true;
    }

    pub fn candidateIsStale(self: *const DaemonRefreshState, account_key: []const u8, now_ns: i128) bool {
        const checked_at = self.candidateCheckedAt(account_key) orelse return true;
        return (now_ns - checked_at) >= api_refresh_interval_ns;
    }
};
