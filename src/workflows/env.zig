const std = @import("std");
const app_runtime = @import("../core/runtime.zig");

pub const skip_service_reconcile_env = "CODEX_AUTH_SKIP_SERVICE_RECONCILE";
pub const account_name_refresh_only_env = "CODEX_AUTH_REFRESH_ACCOUNT_NAMES_ONLY";
pub const disable_background_account_name_refresh_env = "CODEX_AUTH_DISABLE_BACKGROUND_ACCOUNT_NAME_REFRESH";

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

pub fn nowMilliseconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds();
}

pub fn nowSeconds() i64 {
    return std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
}

pub fn hasNonEmptyEnvVar(name: []const u8) bool {
    const value = getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer std.heap.page_allocator.free(value);
    return value.len != 0;
}

pub fn isAccountNameRefreshOnlyMode() bool {
    return hasNonEmptyEnvVar(account_name_refresh_only_env);
}

pub fn isBackgroundAccountNameRefreshDisabled() bool {
    return hasNonEmptyEnvVar(disable_background_account_name_refresh_env);
}
