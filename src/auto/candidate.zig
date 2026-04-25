const std = @import("std");
const registry = @import("../registry/root.zig");

pub const CandidateScore = struct {
    value: i64,
    last_usage_at: i64,
    created_at: i64,
};

pub const candidate_upkeep_refresh_limit: usize = 1;
pub const candidate_switch_validation_limit: usize = 3;

pub const CandidateEntry = struct {
    account_key: []const u8,
    score: CandidateScore,
};

pub const CandidateIndex = struct {
    heap: std.ArrayListUnmanaged(CandidateEntry) = .empty,
    positions: std.StringHashMapUnmanaged(usize) = .empty,
    next_score_change_at: ?i64 = null,

    pub fn deinit(self: *CandidateIndex, allocator: std.mem.Allocator) void {
        self.heap.deinit(allocator);
        self.positions.deinit(allocator);
        self.* = .{};
    }

    pub fn rebuild(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *const registry.Registry, now: i64) !void {
        self.deinit(allocator);
        const active = reg.active_account_key;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            try self.insert(allocator, .{
                .account_key = rec.account_key,
                .score = candidateScore(rec, now),
            });
        }
        self.refreshNextScoreChangeAt(reg, now);
    }

    pub fn rebuildIfScoreExpired(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *const registry.Registry,
        now: i64,
    ) !void {
        if (self.next_score_change_at) |deadline| {
            if (deadline <= now) {
                try self.rebuild(allocator, reg, now);
            }
        }
    }

    pub fn best(self: *const CandidateIndex) ?CandidateEntry {
        if (self.heap.items.len == 0) return null;
        return self.heap.items[0];
    }

    fn insert(self: *CandidateIndex, allocator: std.mem.Allocator, entry: CandidateEntry) !void {
        try self.heap.append(allocator, entry);
        const idx = self.heap.items.len - 1;
        try self.positions.put(allocator, entry.account_key, idx);
        _ = self.siftUp(idx);
    }

    fn remove(self: *CandidateIndex, account_key: []const u8) void {
        const idx = self.positions.get(account_key) orelse return;
        _ = self.positions.remove(account_key);
        const last_idx = self.heap.items.len - 1;
        if (idx != last_idx) {
            self.heap.items[idx] = self.heap.items[last_idx];
            if (self.positions.getPtr(self.heap.items[idx].account_key)) |ptr| {
                ptr.* = idx;
            }
        }
        self.heap.items.len = last_idx;
        if (idx < self.heap.items.len) {
            self.restore(idx);
        }
    }

    pub fn upsertFromRegistry(self: *CandidateIndex, allocator: std.mem.Allocator, reg: *registry.Registry, account_key: []const u8, now: i64) !void {
        if (reg.active_account_key) |active| {
            if (std.mem.eql(u8, active, account_key)) {
                self.remove(account_key);
                self.refreshNextScoreChangeAt(reg, now);
                return;
            }
        }

        const idx = registry.findAccountIndexByAccountKey(reg, account_key) orelse {
            self.remove(account_key);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        };
        const entry: CandidateEntry = .{
            .account_key = reg.accounts.items[idx].account_key,
            .score = candidateScore(&reg.accounts.items[idx], now),
        };
        if (self.positions.get(entry.account_key)) |heap_idx| {
            self.heap.items[heap_idx] = entry;
            self.restore(heap_idx);
            self.refreshNextScoreChangeAt(reg, now);
            return;
        }
        try self.insert(allocator, entry);
        self.refreshNextScoreChangeAt(reg, now);
    }

    pub fn handleActiveSwitch(
        self: *CandidateIndex,
        allocator: std.mem.Allocator,
        reg: *registry.Registry,
        old_active_account_key: []const u8,
        new_active_account_key: []const u8,
        now: i64,
    ) !void {
        self.remove(new_active_account_key);
        try self.upsertFromRegistry(allocator, reg, old_active_account_key, now);
    }

    fn refreshNextScoreChangeAt(self: *CandidateIndex, reg: *const registry.Registry, now: i64) void {
        const active = reg.active_account_key;
        var next_score_change_at: ?i64 = null;
        for (reg.accounts.items) |*rec| {
            if (active) |account_key| {
                if (std.mem.eql(u8, rec.account_key, account_key)) continue;
            }
            next_score_change_at = earlierFutureTimestamp(
                next_score_change_at,
                candidateScoreChangeAt(rec.last_usage, now),
                now,
            );
        }
        self.next_score_change_at = next_score_change_at;
    }

    pub fn orderedKeys(self: *const CandidateIndex, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var ordered = try std.ArrayList([]const u8).initCapacity(allocator, self.heap.items.len);
        for (self.heap.items) |entry| {
            try ordered.append(allocator, entry.account_key);
        }
        std.sort.block([]const u8, ordered.items, self, candidateEntryLessThan);
        return ordered;
    }

    fn candidateEntryLessThan(self: *const CandidateIndex, lhs: []const u8, rhs: []const u8) bool {
        const left_idx = self.positions.get(lhs) orelse return false;
        const right_idx = self.positions.get(rhs) orelse return false;
        const left = self.heap.items[left_idx].score;
        const right = self.heap.items[right_idx].score;
        return candidateBetter(left, right);
    }

    fn restore(self: *CandidateIndex, idx: usize) void {
        if (!self.siftUp(idx)) {
            self.siftDown(idx);
        }
    }

    fn siftUp(self: *CandidateIndex, start_idx: usize) bool {
        var idx = start_idx;
        var moved = false;
        while (idx > 0) {
            const parent_idx = (idx - 1) / 2;
            if (!candidateBetter(self.heap.items[idx].score, self.heap.items[parent_idx].score)) break;
            self.swap(idx, parent_idx);
            idx = parent_idx;
            moved = true;
        }
        return moved;
    }

    fn siftDown(self: *CandidateIndex, start_idx: usize) void {
        var idx = start_idx;
        while (true) {
            const left = idx * 2 + 1;
            if (left >= self.heap.items.len) break;
            const right = left + 1;
            var best_idx = left;
            if (right < self.heap.items.len and candidateBetter(self.heap.items[right].score, self.heap.items[left].score)) {
                best_idx = right;
            }
            if (!candidateBetter(self.heap.items[best_idx].score, self.heap.items[idx].score)) break;
            self.swap(idx, best_idx);
            idx = best_idx;
        }
    }

    fn swap(self: *CandidateIndex, a: usize, b: usize) void {
        if (a == b) return;
        std.mem.swap(CandidateEntry, &self.heap.items[a], &self.heap.items[b]);
        if (self.positions.getPtr(self.heap.items[a].account_key)) |ptr| ptr.* = a;
        if (self.positions.getPtr(self.heap.items[b].account_key)) |ptr| ptr.* = b;
    }
};

pub fn candidateScore(rec: *const registry.AccountRecord, now: i64) CandidateScore {
    const usage_score = registry.usageScoreAt(rec.last_usage, now) orelse 100;
    return .{
        .value = usage_score,
        .last_usage_at = rec.last_usage_at orelse -1,
        .created_at = rec.created_at,
    };
}

pub fn candidateBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.value != b.value) return a.value > b.value;
    if (a.last_usage_at != b.last_usage_at) return a.last_usage_at > b.last_usage_at;
    return a.created_at > b.created_at;
}

pub fn candidateScoreChangeAt(usage: ?registry.RateLimitSnapshot, now: i64) ?i64 {
    if (usage == null) return null;
    var next_change_at: ?i64 = null;
    if (usage.?.primary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    if (usage.?.secondary) |window| {
        next_change_at = earlierFutureTimestamp(next_change_at, window.resets_at, now);
    }
    return next_change_at;
}

pub fn earlierFutureTimestamp(current: ?i64, candidate: ?i64, now: i64) ?i64 {
    if (candidate == null or candidate.? <= now) return current;
    if (current == null) return candidate.?;
    return @min(current.?, candidate.?);
}
