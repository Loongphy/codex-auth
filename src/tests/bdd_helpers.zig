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

pub fn authJsonWithEmailPlan(allocator: std.mem.Allocator, email: []const u8, plan: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"email\":\"{s}\",\"https://api.openai.com/auth\":{{\"chatgpt_plan_type\":\"{s}\"}}}}",
        .{ email, plan },
    );
    defer allocator.free(payload);
    return try authJsonFromPayload(allocator, payload);
}

pub fn authJsonWithoutEmail(allocator: std.mem.Allocator) ![]u8 {
    return try authJsonFromPayload(allocator, "{\"sub\":\"missing-email\"}");
}

pub fn makeEmptyRegistry() registry.Registry {
    return registry.Registry{
        .version = 3,
        .active_email = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
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
    const rec = registry.AccountRecord{
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = std.time.timestamp(),
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    };
    try reg.accounts.append(allocator, rec);
}

pub fn findAccountIndexByEmail(reg: *registry.Registry, email: []const u8) ?usize {
    for (reg.accounts.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.email, email)) return i;
    }
    return null;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}
