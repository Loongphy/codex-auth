const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const common = @import("common.zig");
const clean = @import("clean.zig");
const import_types = @import("import_types.zig");
const import_helpers = @import("import_helpers.zig");

const Registry = common.Registry;
const accountSnapshotFileName = common.accountSnapshotFileName;
const backupDir = clean.backupDir;
const ImportReport = import_types.ImportReport;
const importDisplayLabelFromName = import_helpers.importDisplayLabelFromName;
const importReasonLabel = import_helpers.importReasonLabel;
const isImportSkippableBatchEntryError = import_helpers.isImportSkippableBatchEntryError;
const isPurgeImportAuthFile = import_helpers.isPurgeImportAuthFile;
const accountRecordOrderLessThan = import_helpers.accountRecordOrderLessThan;

pub fn importAccountsSnapshotDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    import_auth_file: anytype,
) !ImportReport {
    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, "~/.codex/accounts");

    const dir_path = try backupDir(allocator, codex_home);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return report,
        else => return err,
    };
    defer dir.close(app_runtime.io());

    var candidates = std.ArrayList(PurgeImportCandidate).empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isPurgeImportAuthFile(entry.name)) continue;

        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        var file_path_owned = true;
        errdefer if (file_path_owned) allocator.free(file_path);

        const label = try importDisplayLabelFromName(allocator, entry.name);
        defer allocator.free(label);

        const stat = dir.statFile(app_runtime.io(), entry.name, .{}) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        var info = @import("../auth/auth.zig").parseAuthInfo(allocator, file_path) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        defer info.deinit(allocator);

        const email = info.email orelse {
            try report.addEvent(allocator, label, .skipped, importReasonLabel(error.MissingEmail));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };
        const record_key = info.record_key orelse {
            try report.addEvent(allocator, label, .skipped, importReasonLabel(error.MissingChatgptUserId));
            file_path_owned = false;
            allocator.free(file_path);
            continue;
        };

        const canonical_name = try accountSnapshotFileName(allocator, record_key);
        defer allocator.free(canonical_name);

        const candidate_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(candidate_name);
        const candidate_record_key = try allocator.dupe(u8, record_key);
        errdefer allocator.free(candidate_record_key);
        const candidate_email = try allocator.dupe(u8, email);
        errdefer allocator.free(candidate_email);

        var candidate = PurgeImportCandidate{
            .name = candidate_name,
            .path = file_path,
            .record_key = candidate_record_key,
            .email = candidate_email,
            .mtime = stat.mtime.nanoseconds,
            .kind = if (std.mem.eql(u8, entry.name, canonical_name))
                .current_snapshot
            else if (std.mem.startsWith(u8, entry.name, "auth.json.bak."))
                .backup
            else
                .legacy_snapshot,
        };
        errdefer candidate.deinit(allocator);
        file_path_owned = false;

        if (findPurgeImportCandidateIndexByRecordKey(candidates.items, candidate.record_key)) |idx| {
            if (purgeImportCandidateIsNewer(&candidates.items[idx], &candidate)) {
                try report.addEvent(allocator, candidates.items[idx].name, .skipped, "SupersededByNewerSnapshot");
                candidates.items[idx].deinit(allocator);
                candidates.items[idx] = candidate;
            } else {
                try report.addEvent(allocator, candidate.name, .skipped, "SupersededByNewerSnapshot");
                candidate.deinit(allocator);
            }
            continue;
        }

        try candidates.append(allocator, candidate);
    }

    std.sort.insertion(PurgeImportCandidate, candidates.items, {}, purgeImportCandidateLessThan);

    for (candidates.items) |candidate| {
        const label = try importDisplayLabelFromName(allocator, candidate.name);
        defer allocator.free(label);
        const outcome = import_auth_file(allocator, codex_home, reg, candidate.path, null) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }
    return report;
}

const PurgeImportCandidateKind = enum(u8) {
    legacy_snapshot,
    backup,
    current_snapshot,
};

const PurgeImportCandidate = struct {
    name: []u8,
    path: []u8,
    record_key: []u8,
    email: []u8,
    mtime: i128,
    kind: PurgeImportCandidateKind,

    fn deinit(self: *PurgeImportCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.record_key);
        allocator.free(self.email);
    }
};

fn purgeImportCandidateRank(kind: PurgeImportCandidateKind) u8 {
    return switch (kind) {
        .legacy_snapshot => 0,
        .backup => 1,
        .current_snapshot => 2,
    };
}

fn purgeImportCandidateIsNewer(current: *const PurgeImportCandidate, incoming: *const PurgeImportCandidate) bool {
    if (incoming.mtime != current.mtime) return incoming.mtime > current.mtime;

    const incoming_rank = purgeImportCandidateRank(incoming.kind);
    const current_rank = purgeImportCandidateRank(current.kind);
    if (incoming_rank != current_rank) return incoming_rank > current_rank;

    return std.mem.order(u8, incoming.name, current.name) == .gt;
}

fn findPurgeImportCandidateIndexByRecordKey(candidates: []const PurgeImportCandidate, record_key: []const u8) ?usize {
    for (candidates, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate.record_key, record_key)) return idx;
    }
    return null;
}

fn purgeImportCandidateLessThan(_: void, a: PurgeImportCandidate, b: PurgeImportCandidate) bool {
    return accountRecordOrderLessThan(a.email, a.record_key, b.email, b.record_key);
}
