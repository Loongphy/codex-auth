const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const common = @import("common.zig");
const clean = @import("clean.zig");
const parse = @import("parse.zig");
const account_ops = @import("account_ops.zig");

const PlanType = common.PlanType;
const AutoSwitchConfig = common.AutoSwitchConfig;
const ApiConfig = common.ApiConfig;
const AccountRecord = common.AccountRecord;
const Registry = common.Registry;
const defaultAutoSwitchConfig = common.defaultAutoSwitchConfig;
const defaultApiConfig = common.defaultApiConfig;
const freeAccountRecord = common.freeAccountRecord;
const normalizeEmailAlloc = common.normalizeEmailAlloc;
const activeAuthPath = common.activeAuthPath;
const accountAuthPath = common.accountAuthPath;
const accountSnapshotFileName = common.accountSnapshotFileName;
const legacyAccountAuthPath = common.legacyAccountAuthPath;
const ensureAccountsDir = common.ensureAccountsDir;
const copyManagedFile = common.copyManagedFile;
const writeFile = common.writeFile;
const readFileAlloc = common.readFileAlloc;
const resolveUserHome = common.resolveUserHome;
const cloneOptionalStringAlloc = common.cloneOptionalStringAlloc;
const getNonEmptyEnvVarOwned = common.getNonEmptyEnvVarOwned;
const registryPath = common.registryPath;
const backupAuthIfChanged = clean.backupAuthIfChanged;
const backupDir = clean.backupDir;
const parseAutoSwitch = parse.parseAutoSwitch;
const parseApiConfig = parse.parseApiConfig;
const findAccountIndexByAccountKey = account_ops.findAccountIndexByAccountKey;
const setActiveAccountKey = account_ops.setActiveAccountKey;
const activateAccountByKey = account_ops.activateAccountByKey;
const accountFromAuth = account_ops.accountFromAuth;
const upsertAccount = account_ops.upsertAccount;

fn defaultRegistry() Registry {
    return Registry{
        .schema_version = common.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = defaultAutoSwitchConfig(),
        .api = defaultApiConfig(),
        .accounts = std.ArrayList(AccountRecord).empty,
    };
}

const import_types = @import("import_types.zig");
const import_carry = @import("import_carry.zig");
const import_helpers = @import("import_helpers.zig");
const import_snapshots = @import("import_snapshots.zig");
pub const ImportRenderKind = import_types.ImportRenderKind;
pub const ImportOutcome = import_types.ImportOutcome;
pub const ImportEvent = import_types.ImportEvent;
pub const ImportReport = import_types.ImportReport;
const loadPurgeCarryForwardConfig = import_carry.loadPurgeCarryForwardConfig;
const importDisplayLabelFromName = import_helpers.importDisplayLabelFromName;
const importDisplayLabel = import_helpers.importDisplayLabel;
const importReasonLabel = import_helpers.importReasonLabel;
const isImportValidationError = import_helpers.isImportValidationError;
const isImportSourceFileError = import_helpers.isImportSourceFileError;
const isImportSkippableBatchEntryError = import_helpers.isImportSkippableBatchEntryError;
const isImportConfigFile = import_helpers.isImportConfigFile;
const importFileNameLessThan = import_helpers.importFileNameLessThan;
pub const importAccountsSnapshotDirectory = import_snapshots.importAccountsSnapshotDirectory;
const sortAccountsByEmail = import_helpers.sortAccountsByEmail;

pub fn purgeRegistryFromImportSourceWithSaver(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    auth_path: ?[]const u8,
    explicit_alias: ?[]const u8,
    save_registry: anytype,
) !ImportReport {
    if (auth_path == null and explicit_alias != null) {
        std.log.warn("--alias is ignored when purging from {s}", .{"~/.codex/accounts"});
    }

    const carry_forward = try loadPurgeCarryForwardConfig(allocator, codex_home);

    var reg = defaultRegistry();
    reg.auto_switch = carry_forward.auto_switch;
    reg.api = carry_forward.api;
    reg.live = carry_forward.live;
    defer reg.deinit(allocator);

    var report = if (auth_path) |path|
        try importAuthPath(allocator, codex_home, &reg, path, explicit_alias)
    else
        try import_snapshots.importAccountsSnapshotDirectory(allocator, codex_home, &reg, importAuthFile);
    errdefer report.deinit(allocator);
    report.render_kind = .scanned;
    if (report.source_label == null) {
        report.source_label = try allocator.dupe(u8, auth_path orelse "~/.codex/accounts");
    }
    if (report.failure != null) {
        return report;
    }

    if (try syncCurrentAuthBestEffort(allocator, codex_home, &reg)) |outcome| {
        try report.addEvent(allocator, "auth.json (active)", outcome, null);
    }

    sortAccountsByEmail(&reg);
    if (reg.active_account_key == null and reg.accounts.items.len > 0) {
        try activateAccountByKey(allocator, codex_home, &reg, reg.accounts.items[0].account_key);
    }
    try save_registry(allocator, codex_home, &reg);
    return report;
}

pub fn importCpaPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: ?[]const u8,
    explicit_alias: ?[]const u8,
) !ImportReport {
    if (auth_path == null) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{"~/.cli-proxy-api"});
        }
        const default_path = try defaultCpaImportPath(allocator);
        defer allocator.free(default_path);
        return try importCpaDirectory(allocator, codex_home, reg, default_path, "~/.cli-proxy-api", false);
    }

    const path = auth_path.?;
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), path, .{}) catch |err| switch (err) {
        error.IsDir => {
            if (explicit_alias != null) {
                std.log.warn("--alias is ignored when importing a directory: {s}", .{path});
            }
            return try importCpaDirectory(allocator, codex_home, reg, path, path, false);
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{path});
        }
        return try importCpaDirectory(allocator, codex_home, reg, path, path, false);
    }

    var report = ImportReport.init(.single_file);
    errdefer report.deinit(allocator);

    const outcome = importCpaFile(allocator, codex_home, reg, path, explicit_alias) catch |err| {
        if (!isImportValidationError(err) and !isImportSourceFileError(err)) return err;
        const label = try importDisplayLabel(allocator, path);
        defer allocator.free(label);
        try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
        report.failure = err;
        return report;
    };

    const label = try importDisplayLabel(allocator, path);
    defer allocator.free(label);
    try report.addEvent(allocator, label, outcome, null);
    return report;
}

pub fn importAuthPath(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_path: []const u8,
    explicit_alias: ?[]const u8,
) !ImportReport {
    const stat = std.Io.Dir.cwd().statFile(app_runtime.io(), auth_path, .{}) catch |err| switch (err) {
        error.IsDir => {
            if (explicit_alias != null) {
                std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
            }
            return try importAuthDirectory(allocator, codex_home, reg, auth_path);
        },
        else => return err,
    };
    if (stat.kind == .directory) {
        if (explicit_alias != null) {
            std.log.warn("--alias is ignored when importing a directory: {s}", .{auth_path});
        }
        return try importAuthDirectory(allocator, codex_home, reg, auth_path);
    }

    var report = ImportReport.init(.single_file);
    errdefer report.deinit(allocator);

    const outcome = importAuthFile(allocator, codex_home, reg, auth_path, explicit_alias) catch |err| {
        if (!isImportValidationError(err)) return err;
        const label = try importDisplayLabel(allocator, auth_path);
        defer allocator.free(label);
        try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
        report.failure = err;
        return report;
    };

    const label = try importDisplayLabel(allocator, auth_path);
    defer allocator.free(label);
    try report.addEvent(allocator, label, outcome, null);
    return report;
}

fn defaultCpaImportPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try resolveUserHome(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cli-proxy-api" });
}

fn importCpaFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
) !ImportOutcome {
    var file = try std.Io.Dir.cwd().openFile(app_runtime.io(), auth_file, .{});
    defer file.close(app_runtime.io());

    const data = try readFileAlloc(file, allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const converted = try @import("../auth/auth.zig").convertCpaAuthJson(allocator, data);
    defer allocator.free(converted);

    const info = try @import("../auth/auth.zig").parseAuthInfoData(allocator, converted);
    defer info.deinit(allocator);

    return try importConvertedAuthInfo(allocator, codex_home, reg, explicit_alias, &info, converted);
}

fn importConvertedAuthInfo(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    explicit_alias: ?[]const u8,
    info: *const @import("../auth/auth.zig").AuthInfo,
    auth_data: []const u8,
) !ImportOutcome {
    _ = info.email orelse return error.MissingEmail;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const alias = explicit_alias orelse "";
    const existed = findAccountIndexByAccountKey(reg, record_key) != null;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try writeFile(dest, auth_data);

    const record = try accountFromAuth(allocator, alias, info);
    try upsertAccount(allocator, reg, record);
    return if (existed) .updated else .imported;
}

fn importAuthFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
) !ImportOutcome {
    const info = try @import("../auth/auth.zig").parseAuthInfo(allocator, auth_file);
    defer info.deinit(allocator);
    return try importAuthInfo(allocator, codex_home, reg, auth_file, explicit_alias, &info);
}

fn importAuthInfo(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    auth_file: []const u8,
    explicit_alias: ?[]const u8,
    info: *const @import("../auth/auth.zig").AuthInfo,
) !ImportOutcome {
    _ = info.email orelse return error.MissingEmail;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const alias = explicit_alias orelse "";
    const existed = findAccountIndexByAccountKey(reg, record_key) != null;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyManagedFile(auth_file, dest);

    const record = try accountFromAuth(allocator, alias, info);
    try upsertAccount(allocator, reg, record);
    return if (existed) .updated else .imported;
}

fn importCpaDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    dir_path: []const u8,
    source_label: []const u8,
    missing_ok: bool,
) !ImportReport {
    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, source_label);

    var dir = std.Io.Dir.cwd().openDir(app_runtime.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => if (missing_ok) return report else return err,
        else => return err,
    };
    defer dir.close(app_runtime.io());

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImportConfigFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.insertion([]u8, names.items, {}, importFileNameLessThan);

    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
        defer allocator.free(file_path);
        const label = try importDisplayLabelFromName(allocator, name);
        defer allocator.free(label);
        const outcome = importCpaFile(allocator, codex_home, reg, file_path, null) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }

    return report;
}

fn importAuthDirectory(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
    dir_path: []const u8,
) !ImportReport {
    var dir = try std.Io.Dir.cwd().openDir(app_runtime.io(), dir_path, .{ .iterate = true });
    defer dir.close(app_runtime.io());

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(app_runtime.io())) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!isImportConfigFile(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.sort.insertion([]u8, names.items, {}, importFileNameLessThan);

    var report = ImportReport.init(.scanned);
    errdefer report.deinit(allocator);
    report.source_label = try allocator.dupe(u8, dir_path);
    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
        defer allocator.free(file_path);
        const label = try importDisplayLabelFromName(allocator, name);
        defer allocator.free(label);
        const info = @import("../auth/auth.zig").parseAuthInfo(allocator, file_path) catch |err| {
            if (!isImportSkippableBatchEntryError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        defer info.deinit(allocator);
        const outcome = importAuthInfo(allocator, codex_home, reg, file_path, null, &info) catch |err| {
            if (!isImportValidationError(err)) return err;
            try report.addEvent(allocator, label, .skipped, importReasonLabel(err));
            continue;
        };
        try report.addEvent(allocator, label, outcome, null);
    }
    return report;
}

fn syncCurrentAuthBestEffort(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *Registry,
) !?ImportOutcome {
    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    if (std.Io.Dir.cwd().openFile(app_runtime.io(), auth_path, .{})) |file| {
        file.close(app_runtime.io());
    } else |_| {
        return null;
    }

    const info = @import("../auth/auth.zig").parseAuthInfo(allocator, auth_path) catch return null;
    defer info.deinit(allocator);
    _ = info.email orelse return null;
    const record_key = info.record_key orelse return null;

    const existing_idx = findAccountIndexByAccountKey(reg, record_key);
    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);
    try ensureAccountsDir(allocator, codex_home);
    try copyManagedFile(auth_path, dest);

    if (existing_idx) |idx| {
        const email = info.email.?;
        if (!std.mem.eql(u8, reg.accounts.items[idx].email, email)) {
            const new_email = try allocator.dupe(u8, email);
            allocator.free(reg.accounts.items[idx].email);
            reg.accounts.items[idx].email = new_email;
        }
        if (info.chatgpt_account_id) |chatgpt_account_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_account_id, chatgpt_account_id)) {
                const new_chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id);
                allocator.free(reg.accounts.items[idx].chatgpt_account_id);
                reg.accounts.items[idx].chatgpt_account_id = new_chatgpt_account_id;
            }
        }
        if (info.chatgpt_user_id) |chatgpt_user_id| {
            if (!std.mem.eql(u8, reg.accounts.items[idx].chatgpt_user_id, chatgpt_user_id)) {
                const new_chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id);
                allocator.free(reg.accounts.items[idx].chatgpt_user_id);
                reg.accounts.items[idx].chatgpt_user_id = new_chatgpt_user_id;
            }
        }
        reg.accounts.items[idx].plan = info.plan;
        reg.accounts.items[idx].auth_mode = info.auth_mode;
    } else {
        var record = try accountFromAuth(allocator, "", &info);
        errdefer freeAccountRecord(allocator, &record);
        try upsertAccount(allocator, reg, record);
    }

    try setActiveAccountKey(allocator, reg, record_key);
    return if (existing_idx != null) .updated else .imported;
}
