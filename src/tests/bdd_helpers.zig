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

pub fn accountIdForEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "acc:{s}", .{email});
}

pub fn authJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const account_id = try accountIdForEmailAlloc(allocator, email);
    defer allocator.free(account_id);
    const access_token = try std.fmt.allocPrint(allocator, "access-{s}", .{email});
    defer allocator.free(access_token);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, account_id, plan },
    );
    defer allocator.free(payload);
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"{s}\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ access_token, account_id, extractToken(auth) },
    );
}

pub fn authJsonWithoutEmail(allocator: std.mem.Allocator) ![]u8 {
    const account_id = "acc:missing-email";
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc:missing-email\",\"chatgpt_plan_type\":\"pro\"},\"sub\":\"missing-email\"}";
    const auth = try authJsonFromPayload(allocator, payload);
    defer allocator.free(auth);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"tokens\":{{\"access_token\":\"access-missing-email\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ account_id, extractToken(auth) },
    );
}

pub fn authJsonWithoutAccountId(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"acc:{s}\",\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, email, plan },
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
        .active_account_id = null,
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
    const account_id = try accountIdForEmailAlloc(allocator, email);
    errdefer allocator.free(account_id);
    const rec = registry.AccountRecord{
        .account_id = account_id,
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
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
