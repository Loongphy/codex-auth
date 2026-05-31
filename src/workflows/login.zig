const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const me_api = @import("../api/me.zig");
const account_names = @import("account_names.zig");
const app_runtime = @import("../core/runtime.zig");

const defaultAccountFetcher = account_names.defaultAccountFetcher;
const refreshAccountNamesAfterLogin = account_names.refreshAccountNamesAfterLogin;

fn loadActiveAuthState(allocator: std.mem.Allocator, auth_path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(app_runtime.io(), auth_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(app_runtime.io());

    return try registry.readFileAlloc(file, allocator, 10 * 1024 * 1024);
}

fn restoreActiveAuthState(auth_path: []const u8, state: ?[]const u8) !void {
    if (state) |data| {
        try registry.writeFile(auth_path, data);
    } else {
        std.Io.Dir.cwd().deleteFile(app_runtime.io(), auth_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LoginOptions) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (reg.accounts.items.len > 0) {
        _ = try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg);
    }

    try registry.ensureAccountsDir(allocator, codex_home);

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);
    const original_auth = try loadActiveAuthState(allocator, auth_path);
    defer if (original_auth) |data| allocator.free(data);
    errdefer |login_err| restoreActiveAuthState(auth_path, original_auth) catch |restore_err| {
        std.log.err(
            "failed to restore auth.json after login failure ({s}): {s}",
            .{ @errorName(login_err), @errorName(restore_err) },
        );
    };

    try cli.login.runCodexLogin(opts, codex_home);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    if (info.auth_mode == .apikey) {
        const api_key = info.openai_api_key orelse return error.MissingOpenAIAPIKey;
        var me = try me_api.fetchMeForApiKey(allocator, api_key);
        defer me.deinit(allocator);

        const record_key = try registry.apiKeyAccountKeyAlloc(allocator, me.user_id, api_key);
        defer allocator.free(record_key);
        const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
        defer allocator.free(dest);

        try registry.ensureAccountsDir(allocator, codex_home);
        try registry.copyManagedFile(auth_path, dest);

        const record = try registry.accountFromApiKeyMe(allocator, "", &info, &me);
        try registry.upsertAccount(allocator, &reg, record);
        try registry.setActiveAccountKey(allocator, &reg, record_key);
        try registry.saveRegistry(allocator, codex_home, &reg);
        return;
    }

    const email = info.email orelse return error.MissingEmail;
    _ = email;
    const record_key = info.record_key orelse return error.MissingChatgptUserId;
    const dest = try registry.accountAuthPath(allocator, codex_home, record_key);
    defer allocator.free(dest);

    try registry.ensureAccountsDir(allocator, codex_home);
    try registry.copyManagedFile(auth_path, dest);

    const record = try registry.accountFromAuth(allocator, "", &info);
    try registry.upsertAccount(allocator, &reg, record);
    try registry.setActiveAccountKey(allocator, &reg, record_key);
    _ = try refreshAccountNamesAfterLogin(allocator, &reg, &info, defaultAccountFetcher);
    try registry.saveRegistry(allocator, codex_home, &reg);
}
