const std = @import("std");
const auth = @import("auth.zig");
const registry = @import("registry.zig");

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

        try candidates.append(allocator, .{
            .chatgpt_user_id = try allocator.dupe(u8, rec.chatgpt_user_id),
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
        if (info.access_token == null) {
            var owned_info = info;
            owned_info.deinit(allocator);
            continue;
        }
        return info;
    }

    return null;
}
