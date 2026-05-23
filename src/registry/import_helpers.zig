const std = @import("std");
const common = @import("common.zig");

const AccountRecord = common.AccountRecord;
const Registry = common.Registry;

pub fn importDisplayLabelFromName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return allocator.dupe(u8, name);
}

pub fn importDisplayLabel(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return importDisplayLabelFromName(allocator, std.fs.path.basename(path));
}

pub fn importReasonLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        => "InvalidJSON",
        error.StreamTooLong => "MaxFileSizeExceeded",
        else => @errorName(err),
    };
}

pub fn isImportValidationError(err: anyerror) bool {
    return switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.InvalidCPAFormat,
        error.MissingEmail,
        error.MissingChatgptUserId,
        error.MissingOpenAIAPIKey,
        error.MissingOpenAIUserId,
        error.InvalidOpenAIMeResponse,
        error.OpenAIMeRequestFailed,
        error.MissingAccountId,
        error.MissingRefreshToken,
        error.AccountIdMismatch,
        error.InvalidJwt,
        error.InvalidBase64,
        => true,
        else => false,
    };
}

pub fn isImportSourceFileError(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.IsDir,
        error.NotDir,
        error.StreamTooLong,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

pub fn isImportSkippableBatchEntryError(err: anyerror) bool {
    return isImportValidationError(err) or isImportSourceFileError(err);
}

pub fn isImportConfigFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".json");
}

pub fn isPurgeImportAuthFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".auth.json") or
        std.mem.startsWith(u8, name, "auth.json.bak.");
}

pub fn importFileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn accountRecordOrderLessThan(a_email: []const u8, a_account_key: []const u8, b_email: []const u8, b_account_key: []const u8) bool {
    return switch (std.mem.order(u8, a_email, b_email)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a_account_key, b_account_key),
    };
}

pub fn accountRecordLessThan(_: void, a: AccountRecord, b: AccountRecord) bool {
    return accountRecordOrderLessThan(a.email, a.account_key, b.email, b.account_key);
}

pub fn sortAccountsByEmail(reg: *Registry) void {
    std.sort.insertion(AccountRecord, reg.accounts.items, {}, accountRecordLessThan);
}
