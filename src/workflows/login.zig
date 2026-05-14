const std = @import("std");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const me_api = @import("../api/me.zig");
const account_names = @import("account_names.zig");

const defaultAccountFetcher = account_names.defaultAccountFetcher;
const refreshAccountNamesAfterLogin = account_names.refreshAccountNamesAfterLogin;

pub fn handleLogin(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.LoginOptions) !void {
    try cli.login.runCodexLogin(opts);
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);

    if (info.auth_mode == .apikey) {
        const api_key = info.openai_api_key orelse return error.MissingOpenAiApiKey;
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
