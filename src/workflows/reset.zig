const std = @import("std");
const chatgpt_http = @import("../api/http.zig");
const usage_api = @import("../api/usage.zig");
const cli = @import("../cli/root.zig");
const registry = @import("../registry/root.zig");
const query_mod = @import("query.zig");

pub fn handleReset(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.ResetOptions) !void {
    if (!opts.yes) {
        try cli.output.printResetRequiresYesError();
        return error.ResetRequiresConfirmation;
    }

    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }

    const idx = try resolveResetTargetIndex(allocator, &reg, opts.selector);
    const rec = &reg.accounts.items[idx];
    if (rec.auth_mode != null and rec.auth_mode.? == .apikey) {
        try cli.output.printResetUnsupportedAuthModeError(rec.email);
        return error.UnsupportedAuthMode;
    }
    try chatgpt_http.ensureCurlExecutableAvailable(allocator);

    const auth_path = try registry.accountAuthPath(allocator, codex_home, rec.account_key);
    defer allocator.free(auth_path);

    var result = usage_api.consumeResetForAuthPath(allocator, auth_path) catch |err| {
        try cli.output.printResetConsumeFailedError(@errorName(err));
        return err;
    };
    defer result.deinit(allocator);

    if (rec.last_usage) |*snapshot| {
        if (snapshot.reset_credits) |count| {
            snapshot.reset_credits = @max(count - 1, 0);
        }
    }
    try registry.saveRegistry(allocator, codex_home, &reg);
    try cli.output.printResetConsumed(allocator, &reg, rec.account_key, &result);
}

fn resolveResetTargetIndex(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    selector: []const u8,
) !usize {
    var resolution = try query_mod.resolveSwitchQueryLocally(allocator, reg, selector);
    defer resolution.deinit(allocator);

    const account_key = switch (resolution) {
        .not_found => {
            try cli.output.printResetAccountNotFoundError(selector);
            return error.AccountNotFound;
        },
        .direct => |key| key,
        .multiple => {
            try cli.output.printResetMultipleTargetsError(selector);
            return error.MultipleAccountsMatched;
        },
    };
    return registry.findAccountIndexByAccountKey(reg, account_key) orelse error.AccountNotFound;
}
