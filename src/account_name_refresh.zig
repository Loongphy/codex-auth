const std = @import("std");
const fs = @import("compat_fs.zig");
const auth = @import("auth.zig");
const registry = @import("registry.zig");

pub const BackgroundRefreshLock = struct {
    file: fs.File,

    pub fn acquire(allocator: std.mem.Allocator, codex_home: []const u8) !?BackgroundRefreshLock {
        try registry.ensureAccountsDir(allocator, codex_home);
        const path = try fs.path.join(allocator, &[_][]const u8{
            codex_home,
            "accounts",
            registry.account_name_refresh_lock_file_name,
        });
        defer allocator.free(path);

        var file = try fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        errdefer file.close();
        if (!(try tryExclusiveLock(file))) {
            file.close();
            return null;
        }
        return .{ .file = file };
    }

    pub fn release(self: *BackgroundRefreshLock) void {
        self.file.unlock();
        self.file.close();
    }
};

pub const Candidate = struct {
    chatgpt_user_id: []u8,

    pub fn deinit(self: *const Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.chatgpt_user_id);
    }
};

fn hasCandidate(candidates: []const Candidate, chatgpt_user_id: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.chatgpt_user_id, chatgpt_user_id)) return true;
    }
    return false;
}

fn candidateIsNewer(candidate: *const auth.AuthInfo, best: *const auth.AuthInfo) bool {
    const candidate_refresh = candidate.last_refresh orelse return false;
    const best_refresh = best.last_refresh orelse return true;
    return std.mem.order(u8, candidate_refresh, best_refresh) == .gt;
}

fn tryExclusiveLock(file: fs.File) !bool {
    return try file.tryLock(.exclusive);
}

fn storedAuthInfoSupportsAccountNameRefresh(info: *const auth.AuthInfo) bool {
    return info.access_token != null and info.chatgpt_account_id != null;
}

fn considerStoredAuthInfoForRefresh(
    allocator: std.mem.Allocator,
    best_info: *?auth.AuthInfo,
    info: auth.AuthInfo,
) void {
    if (!storedAuthInfoSupportsAccountNameRefresh(&info)) {
        var skipped = info;
        skipped.deinit(allocator);
        return;
    }

    if (best_info.* == null) {
        best_info.* = info;
        return;
    }

    if (candidateIsNewer(&info, &best_info.*.?)) {
        var previous = best_info.*.?;
        previous.deinit(allocator);
        best_info.* = info;
    } else {
        var rejected = info;
        rejected.deinit(allocator);
    }
}

pub fn collectCandidates(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
) !std.ArrayList(Candidate) {
    var candidates = std.ArrayList(Candidate).empty;
    errdefer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    if (!reg.api.account) return candidates;

    for (reg.accounts.items) |rec| {
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;
        if (hasCandidate(candidates.items, rec.chatgpt_user_id)) continue;
        if (!registry.shouldFetchTeamAccountNamesForUser(reg, rec.chatgpt_user_id)) continue;

        const duped_id = try allocator.dupe(u8, rec.chatgpt_user_id);
        errdefer allocator.free(duped_id);
        try candidates.append(allocator, .{
            .chatgpt_user_id = duped_id,
        });
    }

    return candidates;
}

pub fn loadStoredAuthInfoForUser(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *registry.Registry,
    chatgpt_user_id: []const u8,
) !?auth.AuthInfo {
    var best_info: ?auth.AuthInfo = null;
    errdefer if (best_info) |*info| info.deinit(allocator);

    for (reg.accounts.items) |rec| {
        if (!std.mem.eql(u8, rec.chatgpt_user_id, chatgpt_user_id)) continue;
        if (rec.auth_mode != null and rec.auth_mode.? != .chatgpt) continue;

        const auth_path = try registry.accountAuthPath(allocator, codex_home, rec.account_key);
        defer allocator.free(auth_path);

        const info = auth.parseAuthInfo(allocator, auth_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => continue,
            else => {
                std.log.warn("account metadata refresh skipped: {s}", .{@errorName(err)});
                continue;
            },
        };
        considerStoredAuthInfoForRefresh(allocator, &best_info, info);
    }

    return best_info;
}

fn makeStoredAuthInfoForTest(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    chatgpt_account_id: ?[]const u8,
    last_refresh: []const u8,
) !auth.AuthInfo {
    return .{
        .email = null,
        .chatgpt_account_id = if (chatgpt_account_id) |account_id| try allocator.dupe(u8, account_id) else null,
        .chatgpt_user_id = try allocator.dupe(u8, "user-1"),
        .record_key = null,
        .access_token = try allocator.dupe(u8, access_token),
        .last_refresh = try allocator.dupe(u8, last_refresh),
        .plan = null,
        .auth_mode = .chatgpt,
    };
}

test "stored auth selection skips newer snapshots missing account id" {
    const gpa = std.testing.allocator;

    var best_info: ?auth.AuthInfo = null;
    defer if (best_info) |*info| info.deinit(gpa);

    const valid = try makeStoredAuthInfoForTest(
        gpa,
        "stale-token",
        "acct-stale",
        "2026-03-20T00:00:00Z",
    );
    considerStoredAuthInfoForRefresh(gpa, &best_info, valid);

    const missing_account_id = try makeStoredAuthInfoForTest(
        gpa,
        "fresh-token",
        null,
        "2026-03-21T00:00:00Z",
    );
    considerStoredAuthInfoForRefresh(gpa, &best_info, missing_account_id);

    try std.testing.expect(best_info != null);
    try std.testing.expect(std.mem.eql(u8, best_info.?.access_token.?, "stale-token"));
    try std.testing.expect(std.mem.eql(u8, best_info.?.chatgpt_account_id.?, "acct-stale"));
    try std.testing.expect(std.mem.eql(u8, best_info.?.last_refresh.?, "2026-03-20T00:00:00Z"));
}
