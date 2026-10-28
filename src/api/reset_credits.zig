const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const auth = @import("../auth/auth.zig");
const http = @import("http.zig");

pub const default_reset_credits_consume_endpoint =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";

/// Outcome of one consume request, mirroring upstream's
/// `ConsumeRateLimitResetCreditCode` (`reset` / `nothing_to_reset` /
/// `no_credit` / `already_redeemed`).
pub const ConsumeOutcome = enum {
    reset,
    already_redeemed,
    nothing_to_reset,
    no_credit,
    unexpected_response,
    http_error,
    request_error,

    pub fn isSuccess(self: ConsumeOutcome) bool {
        return self == .reset or self == .already_redeemed;
    }
};

pub const ConsumeResult = struct {
    outcome: ConsumeOutcome,
    status_code: ?u16 = null,
    error_name: ?[]const u8 = null,
    body: ?[]const u8 = null,

    pub fn deinit(self: *ConsumeResult, allocator: std.mem.Allocator) void {
        if (self.error_name) |name| allocator.free(name);
        if (self.body) |b| allocator.free(b);
        self.* = undefined;
    }
};

/// Maps the backend `code` field of `ConsumeRateLimitResetCreditResponse` to
/// the local outcome. Unknown or missing codes are unexpected responses.
pub fn parseConsumeOutcome(allocator: std.mem.Allocator, body: []const u8) ConsumeOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return .unexpected_response;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return .unexpected_response,
    };
    const code = switch (root.get("code") orelse return .unexpected_response) {
        .string => |s| s,
        else => return .unexpected_response,
    };
    if (std.mem.eql(u8, code, "reset")) return .reset;
    if (std.mem.eql(u8, code, "already_redeemed")) return .already_redeemed;
    if (std.mem.eql(u8, code, "nothing_to_reset")) return .nothing_to_reset;
    if (std.mem.eql(u8, code, "no_credit")) return .no_credit;
    return .unexpected_response;
}

/// Mirrors upstream: the client generates the idempotency key (UUID v4) and
/// sends it as `redeem_request_id` together with the chosen `credit_id`.
/// Callers must reuse the same key when retrying the same credit so the
/// backend deduplicates the request instead of consuming a second credit.
pub fn generateIdempotencyKeyAlloc(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    app_runtime.io().random(&raw);
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

/// Builds the consume request body. `credit_id` originates at the backend and
/// round-trips through the stored registry, so both fields are JSON-encoded
/// instead of interpolated into body text.
pub fn buildConsumeBodyAlloc(
    allocator: std.mem.Allocator,
    redeem_request_id: []const u8,
    credit_id: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .redeem_request_id = redeem_request_id,
        .credit_id = credit_id,
    }, .{});
}

fn fail(allocator: std.mem.Allocator, name: []const u8) ConsumeResult {
    return .{
        .outcome = .request_error,
        .status_code = null,
        .error_name = allocator.dupe(u8, name) catch null,
        .body = null,
    };
}

/// Redeems one reset credit for the given account via the backend consume
/// endpoint, using `redeem_request_id` as the idempotency key. The account
/// must be a ChatGPT-auth account with a usable token.
pub fn consumeCreditForAccount(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    account_key: []const u8,
    redeem_request_id: []const u8,
    credit_id: []const u8,
) !ConsumeResult {
    const auth_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(auth_path);

    const info = auth.parseAuthInfo(allocator, auth_path) catch |err| return fail(allocator, @errorName(err));
    defer info.deinit(allocator);

    if (info.auth_mode != .chatgpt) return fail(allocator, "MissingAuth");
    const access_token = info.access_token orelse return fail(allocator, "MissingAuth");
    const chatgpt_account_id = info.chatgpt_account_id orelse return fail(allocator, "MissingAuth");

    const body = try buildConsumeBodyAlloc(allocator, redeem_request_id, credit_id);
    defer allocator.free(body);

    const http_result = http.runPostJsonCommand(
        allocator,
        default_reset_credits_consume_endpoint,
        access_token,
        chatgpt_account_id,
        body,
    ) catch |err| return fail(allocator, @errorName(err));

    const status_code = http_result.status_code;
    if (status_code == null or status_code.? < 200 or status_code.? >= 300) {
        return .{
            .outcome = .http_error,
            .status_code = status_code,
            .error_name = null,
            .body = http_result.body,
        };
    }
    return .{
        .outcome = parseConsumeOutcome(allocator, http_result.body),
        .status_code = status_code,
        .error_name = null,
        .body = http_result.body,
    };
}
