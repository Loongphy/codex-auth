const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const account_api = @import("../api/account.zig");
const common = @import("common.zig");
const clean = @import("clean.zig");
const account_ops = @import("account_ops.zig");
const parse = @import("parse.zig");
const import_mod = @import("import.zig");
const storage = @import("storage.zig");
pub const PlanType = common.PlanType;
pub const AuthMode = common.AuthMode;
pub const current_schema_version = common.current_schema_version;
pub const min_supported_schema_version = common.min_supported_schema_version;
pub const default_auto_switch_threshold_5h_percent = common.default_auto_switch_threshold_5h_percent;
pub const default_auto_switch_threshold_weekly_percent = common.default_auto_switch_threshold_weekly_percent;
pub const account_name_refresh_lock_file_name = common.account_name_refresh_lock_file_name;
pub const private_file_permissions = common.private_file_permissions;
pub const private_dir_permissions = common.private_dir_permissions;
pub const getEnvMap = common.getEnvMap;
pub const getEnvVarOwned = common.getEnvVarOwned;
pub const normalizeEmailAlloc = common.normalizeEmailAlloc;
pub const realPathAlloc = common.realPathAlloc;
pub const readFileAlloc = common.readFileAlloc;
pub const RateLimitWindow = common.RateLimitWindow;
pub const CreditsSnapshot = common.CreditsSnapshot;
pub const RateLimitSnapshot = common.RateLimitSnapshot;
pub const RolloutSignature = common.RolloutSignature;
pub const AutoSwitchConfig = common.AutoSwitchConfig;
pub const ApiConfig = common.ApiConfig;
pub const ApiConfigParseResult = common.ApiConfigParseResult;
pub const default_live_refresh_interval_seconds = common.default_live_refresh_interval_seconds;
pub const min_live_refresh_interval_seconds = common.min_live_refresh_interval_seconds;
pub const max_live_refresh_interval_seconds = common.max_live_refresh_interval_seconds;
pub const LiveConfig = common.LiveConfig;
pub const AccountRecord = common.AccountRecord;
pub const resolvePlan = common.resolvePlan;
pub const resolveDisplayPlan = common.resolveDisplayPlan;
pub const planLabel = common.planLabel;
pub const Registry = common.Registry;
pub const defaultAutoSwitchConfig = common.defaultAutoSwitchConfig;
pub const defaultApiConfig = common.defaultApiConfig;
pub const defaultLiveConfig = common.defaultLiveConfig;
pub const freeAccountRecord = common.freeAccountRecord;
pub const freeRateLimitSnapshot = common.freeRateLimitSnapshot;
pub const freeRolloutSignature = common.freeRolloutSignature;
pub const rolloutSignaturesEqual = common.rolloutSignaturesEqual;
pub const cloneRolloutSignature = common.cloneRolloutSignature;
pub const cloneRateLimitSnapshot = common.cloneRateLimitSnapshot;
pub const setRolloutSignature = common.setRolloutSignature;
pub const setAccountLastLocalRollout = common.setAccountLastLocalRollout;
pub const rateLimitSnapshotsEqual = common.rateLimitSnapshotsEqual;
pub const rateLimitSnapshotEqual = common.rateLimitSnapshotEqual;
pub const rateLimitWindowEqual = common.rateLimitWindowEqual;
pub const creditsEqual = common.creditsEqual;
pub const optionalStringEqual = common.optionalStringEqual;
pub const cloneOptionalStringAlloc = common.cloneOptionalStringAlloc;
pub const replaceOptionalStringAlloc = common.replaceOptionalStringAlloc;
pub const getNonEmptyEnvVarOwned = common.getNonEmptyEnvVarOwned;
pub const resolveExistingCodexHomeOverride = common.resolveExistingCodexHomeOverride;
pub const logCodexHomeResolutionError = common.logCodexHomeResolutionError;
pub const resolveCodexHomeFromEnv = common.resolveCodexHomeFromEnv;
pub const resolveCodexHome = common.resolveCodexHome;
pub const resolveUserHome = common.resolveUserHome;
pub const hardenPathPermissions = common.hardenPathPermissions;
pub const hardenSensitiveFile = common.hardenSensitiveFile;
pub const hardenSensitiveDir = common.hardenSensitiveDir;
pub const ensurePrivateDir = common.ensurePrivateDir;
pub const ensureAccountsDir = common.ensureAccountsDir;
pub const registryPath = common.registryPath;
pub const encodedFileKey = common.encodedFileKey;
pub const keyNeedsFilenameEncoding = common.keyNeedsFilenameEncoding;
pub const accountFileKey = common.accountFileKey;
pub const accountSnapshotFileName = common.accountSnapshotFileName;
pub const accountAuthPath = common.accountAuthPath;
pub const legacyAccountAuthPath = common.legacyAccountAuthPath;
pub const activeAuthPath = common.activeAuthPath;
pub const copyFileWithPermissions = common.copyFileWithPermissions;
pub const existingFilePermissions = common.existingFilePermissions;
pub const copyFile = common.copyFile;
pub const copyManagedFile = common.copyManagedFile;
pub const replaceFilePreservingPermissions = common.replaceFilePreservingPermissions;
pub const writeFile = common.writeFile;
pub const max_backups = common.max_backups;

pub const CleanSummary = clean.CleanSummary;
const fileExists = clean.fileExists;
const readFileIfExists = clean.readFileIfExists;
const filesEqual = clean.filesEqual;
const fileEqualsBytes = clean.fileEqualsBytes;
const backupDir = clean.backupDir;
const makeBackupPath = clean.makeBackupPath;
const pruneBackups = clean.pruneBackups;
const resolveStrictAccountAuthPath = clean.resolveStrictAccountAuthPath;
pub const backupAuthIfChanged = clean.backupAuthIfChanged;
const backupRegistryIfChanged = clean.backupRegistryIfChanged;

pub fn cleanAccountsBackups(allocator: std.mem.Allocator, codex_home: []const u8) !CleanSummary {
    return clean.cleanAccountsBackupsWithLoader(allocator, codex_home, loadRegistry);
}

pub const ImportRenderKind = import_mod.ImportRenderKind;
pub const ImportOutcome = import_mod.ImportOutcome;
pub const ImportEvent = import_mod.ImportEvent;
pub const ImportReport = import_mod.ImportReport;
pub fn purgeRegistryFromImportSource(allocator: std.mem.Allocator, codex_home: []const u8, auth_path: ?[]const u8, alias: ?[]const u8) !ImportReport {
    return import_mod.purgeRegistryFromImportSourceWithSaver(allocator, codex_home, auth_path, alias, saveRegistry);
}
pub const importCpaPath = import_mod.importCpaPath;
pub const importAuthPath = import_mod.importAuthPath;
const importCpaFile = import_mod.importCpaFile;
const importConvertedAuthInfo = import_mod.importConvertedAuthInfo;
const importAuthFile = import_mod.importAuthFile;
const importAuthInfo = import_mod.importAuthInfo;
const importAccountsSnapshotDirectory = import_mod.importAccountsSnapshotDirectory;
const sortAccountsByEmail = import_mod.sortAccountsByEmail;
const syncCurrentAuthBestEffort = import_mod.syncCurrentAuthBestEffort;

pub const findAccountIndexByAccountKey = account_ops.findAccountIndexByAccountKey;
pub const setActiveAccountKey = account_ops.setActiveAccountKey;
pub const updateUsage = account_ops.updateUsage;
pub fn syncActiveAccountFromAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    return account_ops.syncActiveAccountFromAuthWithImporter(allocator, codex_home, reg, autoImportActiveAuth);
}
pub const removeAccounts = account_ops.removeAccounts;
pub const selectBestAccountIndexByUsage = account_ops.selectBestAccountIndexByUsage;
pub const usageScoreAt = account_ops.usageScoreAt;
pub const remainingPercentAt = account_ops.remainingPercentAt;
pub const resolveRateWindow = account_ops.resolveRateWindow;
pub const hasMissingAccountNameForUser = account_ops.hasMissingAccountNameForUser;
pub const shouldFetchTeamAccountNamesForUser = account_ops.shouldFetchTeamAccountNamesForUser;
pub const activeChatgptUserId = account_ops.activeChatgptUserId;
pub const applyAccountNamesForUser = account_ops.applyAccountNamesForUser;
pub const activateAccountByKey = account_ops.activateAccountByKey;
pub const replaceActiveAuthWithAccountByKey = account_ops.replaceActiveAuthWithAccountByKey;
pub const accountFromAuth = account_ops.accountFromAuth;
pub const upsertAccount = account_ops.upsertAccount;
const syncActiveAccountFromAuthWithImporter = account_ops.syncActiveAccountFromAuthWithImporter;

pub const loadRegistry = storage.loadRegistry;
pub const saveRegistry = storage.saveRegistry;
const defaultRegistry = storage.defaultRegistry;

pub fn autoImportActiveAuth(allocator: std.mem.Allocator, codex_home: []const u8, reg: *Registry) !bool {
    if (reg.accounts.items.len != 0) return false;

    const auth_path = try activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    if (std.Io.Dir.cwd().openFile(app_runtime.io(), auth_path, .{})) |file| {
        file.close(app_runtime.io());
    } else |_| {
        return false;
    }

    const info = try @import("../auth/auth.zig").parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);
    _ = info.email orelse {
        std.log.warn("auth.json missing email; cannot import", .{});
        return false;
    };
    const record_key = info.record_key orelse return error.MissingChatgptUserId;

    const dest = try accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try ensureAccountsDir(allocator, codex_home);
    try copyManagedFile(auth_path, dest);

    const record = try accountFromAuth(allocator, "", &info);
    try upsertAccount(allocator, reg, record);
    try setActiveAccountKey(allocator, reg, record_key);
    return true;
}
