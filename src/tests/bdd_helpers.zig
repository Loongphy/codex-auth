const std = @import("std");
const registry = @import("../registry.zig");

pub fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

fn authJsonFromPayload(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const h64 = try b64url(allocator, header);
    defer allocator.free(h64);
    const p64 = try b64url(allocator, payload);
    defer allocator.free(p64);
    const jwt = try std.mem.concat(allocator, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer allocator.free(jwt);
    return try std.fmt.allocPrint(allocator, "{{\"tokens\":{{\"id_token\":\"{s}\"}}}}", .{jwt});
}

pub fn accountKeyForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
}

fn hashPart(seed: u64, email: []const u8, modulus: u64) u64 {
    return std.hash.Wyhash.hash(seed, email) % modulus;
}

pub fn chatgptAccountIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d:0>8}-{d:0>4}-{d:0>4}-{d:0>4}-{d:0>12}",
        .{
            hashPart(1, email, 100_000_000),
            hashPart(2, email, 10_000),
            4000 + hashPart(3, email, 1000),
            8000 + hashPart(4, email, 1000),
            hashPart(5, email, 1_000_000_000_000),
        },
    );
}

pub fn chatgptUserIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "user-{x:0>8}{x:0>8}{x:0>6}",
        .{
            hashPart(6, email, 0x100000000),
            hashPart(7, email, 0x100000000),
            hashPart(8, email, 0x1000000),
        },
    );
}

pub fn authJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const access_token = try std.fmt.allocPrint(allocator, "access-{s}", .{email});
    defer allocator.free(access_token);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"{s}\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ access_token, chatgpt_account_id, extractToken(auth) },
    );
}

pub fn cpaJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const access_token = try std.fmt.allocPrint(allocator, "access-{s}", .{email});
    defer allocator.free(access_token);
    const refresh_token = try std.fmt.allocPrint(allocator, "refresh-{s}", .{email});
    defer allocator.free(refresh_token);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"account_id\":\"{s}\",\"last_refresh\":\"2026-03-20T00:00:00Z\"}}",
        .{ email, extractToken(auth), access_token, refresh_token, chatgpt_account_id },
    );
}

pub fn cpaJsonWithoutRefreshToken(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const access_token = try std.fmt.allocPrint(allocator, "access-{s}", .{email});
    defer allocator.free(access_token);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"account_id\":\"{s}\",\"last_refresh\":\"2026-03-20T00:00:00Z\"}}",
        .{ email, extractToken(auth), access_token, chatgpt_account_id },
    );
}

pub fn authJsonWithoutEmail(allocator: std.mem.Allocator) ![]u8 {
    const account_id = "67000000-0000-4000-8000-000000000001";
    const payload =
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"67000000-0000-4000-8000-000000000001\",\"chatgpt_user_id\":\"user-0000000000000000000001\",\"user_id\":\"user-0000000000000000000001\",\"chatgpt_plan_type\":\"pro\"},\"sub\":\"missing-email\"}";
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"access-missing-email\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ account_id, extractToken(auth) },
    );
}

pub fn authJsonWithoutAccountId(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_user_id);
    const chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    defer allocator.free(chatgpt_account_id);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_user_id\":\"{s}\",\"user_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, chatgpt_account_id, chatgpt_user_id, chatgpt_user_id, plan },
    );
    defer allocator.free(payload);
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"access-{s}\",\"id_token\":\"{s}\"}}}}",
        .{ email, extractToken(auth) },
    );
}

pub fn makeEmptyRegistry() registry.Registry {
    return registry.Registry{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

pub fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    email: []const u8,
    alias: []const u8,
    plan: ?registry.PlanType,
) !void {
    const account_id = try accountKeyForEmailAlloc(allocator, email);
    errdefer allocator.free(account_id);
    const owned_email = try allocator.dupe(u8, email);
    errdefer allocator.free(owned_email);
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    const owned_chatgpt_account_id = try chatgptAccountIdForEmailAlloc(allocator, email);
    errdefer allocator.free(owned_chatgpt_account_id);
    const owned_chatgpt_user_id = try chatgptUserIdForEmailAlloc(allocator, email);
    errdefer allocator.free(owned_chatgpt_user_id);
    const rec = registry.AccountRecord{
        .account_key = account_id,
        .chatgpt_account_id = owned_chatgpt_account_id,
        .chatgpt_user_id = owned_chatgpt_user_id,
        .email = owned_email,
        .alias = owned_alias,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    };
    try reg.accounts.append(allocator, rec);
}

pub fn findAccountIndexByEmail(reg: *registry.Registry, email: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.email, email)) return i;
    }
    return null;
}

fn extractToken(auth_json: []const u8) []const u8 {
    const prefix = "{\"tokens\":{\"id_token\":\"";
    const start = std.mem.indexOf(u8, auth_json, prefix).? + prefix.len;
    const end = std.mem.lastIndexOf(u8, auth_json, "\"}}").?;
    return auth_json[start..end];
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
