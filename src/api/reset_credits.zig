const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const http = @import("http.zig");

pub const default_reset_credits_consume_endpoint =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

pub const ConsumeResult = struct {
    ok: bool,
    status_code: ?u16 = null,
    error_name: ?[]const u8 = null,
    body: ?[]const u8 = null,

    pub fn deinit(self: *ConsumeResult, allocator: std.mem.Allocator) void {
        if (self.error_name) |name| allocator.free(name);
        if (self.body) |b| allocator.free(b);
        self.* = undefined;
    }
};

/// Mirrors upstream: the client generates the idempotency key (UUID v4) and
/// sends it as `redeem_request_id` together with the chosen `credit_id`.
fn randomIdempotencyKeyAlloc(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    const nanos = std.Io.Timestamp.now(app_runtime.io(), .real).toNanoseconds();
    var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(nanos))));
    prng.random().bytes(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var read: usize = 0;
    var write: usize = 0;
    while (read < 16) : (read += 1) {
        if (write == 8 or write == 13 or write == 18 or write == 23) {
            out[write] = '-';
            write += 1;
        }
        out[write] = hex[raw[read] >> 4];
        out[write + 1] = hex[raw[read] & 0x0f];
        write += 2;
    }
    return allocator.dupe(u8, out[0..]);
}

fn fail(allocator: std.mem.Allocator, name: []const u8) ConsumeResult {
    return .{
        .ok = false,
        .status_code = null,
        .error_name = allocator.dupe(u8, name) catch null,
        .body = null,
    };
}

/// Redeems one reset credit for the given account via the backend consume
/// endpoint. The account must be a ChatGPT-auth account with a usable token.
pub fn consumeCreditForAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
    credit_id: []const u8,
) !ConsumeResult {
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const info = auth.parseAuthInfo(allocator, auth_path) catch |err| return fail(allocator, @errorName(err));
    defer info.deinit(allocator);

    if (info.auth_mode != .chatgpt) return fail(allocator, "MissingAuth");
    const access_token = info.access_token orelse return fail(allocator, "MissingAuth");
    const chatgpt_account_id = info.chatgpt_account_id orelse return fail(allocator, "MissingAuth");

    const idempotency_key = try randomIdempotencyKeyAlloc(allocator);
    defer allocator.free(idempotency_key);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"redeem_request_id\":\"{s}\",\"credit_id\":\"{s}\"}}",
        .{ idempotency_key, credit_id },
    );
    defer allocator.free(body);

    const http_result = http.runPostJsonCommand(
        allocator,
        default_reset_credits_consume_endpoint,
        access_token,
        chatgpt_account_id,
        body,
    ) catch |err| return fail(allocator, @errorName(err));

    const ok = http_result.status_code != null and
        http_result.status_code.? >= 200 and http_result.status_code.? < 300;
    return .{
        .ok = ok,
        .status_code = http_result.status_code,
        .error_name = null,
        .body = http_result.body,
    };
}
