const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const common = @import("common.zig");
const parse = @import("parse.zig");

const AccountRecord = common.AccountRecord;
const freeAccountRecord = common.freeAccountRecord;
const normalizeEmailAlloc = common.normalizeEmailAlloc;
const parseAuthMode = parse.parseAuthMode;
const parsePlanType = parse.parsePlanType;
const parseRolloutSignature = parse.parseRolloutSignature;
const parseUsage = parse.parseUsage;
const readInt = parse.readInt;

pub fn parseAccountRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !AccountRecord {
    const account_key_val = obj.get("account_key") orelse return error.MissingAccountKey;
    const email_val = obj.get("email") orelse return error.MissingEmail;
    const alias_val = obj.get("alias") orelse return error.MissingAlias;
    const account_key = switch (account_key_val) {
        .string => |s| s,
        else => return error.MissingAccountKey,
    };
    const email = switch (email_val) {
        .string => |s| s,
        else => return error.MissingEmail,
    };
    const alias = switch (alias_val) {
        .string => |s| s,
        else => return error.MissingAlias,
    };
    var rec = AccountRecord{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = switch (obj.get("chatgpt_account_id") orelse return error.MissingChatgptAccountId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptAccountId,
        },
        .chatgpt_user_id = switch (obj.get("chatgpt_user_id") orelse return error.MissingChatgptUserId) {
            .string => |s| try allocator.dupe(u8, s),
            else => return error.MissingChatgptUserId,
        },
        .email = try normalizeEmailAlloc(allocator, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = try parseOptionalStoredStringAlloc(allocator, obj.get("account_name")),
        .plan = null,
        .auth_mode = null,
        .created_at = readInt(obj.get("created_at")) orelse std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds(),
        .last_used_at = readInt(obj.get("last_used_at")),
        .last_usage = null,
        .last_usage_at = readInt(obj.get("last_usage_at")),
        .last_local_rollout = null,
    };
    errdefer freeAccountRecord(allocator, &rec);

    if (obj.get("plan")) |p| {
        switch (p) {
            .string => |s| rec.plan = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("auth_mode")) |m| {
        switch (m) {
            .string => |s| rec.auth_mode = parseAuthMode(s),
            else => {},
        }
    }
    if (obj.get("last_usage")) |u| {
        rec.last_usage = parseUsage(allocator, u);
    }
    if (obj.get("last_local_rollout")) |v| {
        rec.last_local_rollout = parseRolloutSignature(allocator, v);
    }
    return rec;
}

fn parseOptionalStoredStringAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const text = switch (value orelse return null) {
        .string => |s| s,
        .null => return null,
        else => return null,
    };
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}
