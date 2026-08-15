const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("auth.zig");
const http = @import("../api/http.zig");
const registry = @import("../registry/root.zig");
const sensitive_file = @import("../core/sensitive_file.zig");

pub const token_endpoint = "https://auth.openai.com/oauth/token";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const refresh_window_seconds: i64 = 5 * 60;
pub const fallback_max_age_seconds: i64 = 8 * 24 * 60 * 60;

pub const FailureClass = enum { permanent, protocol, transient };
pub const Outcome = enum { fresh, refreshed };

pub fn classifyFailure(status: ?u16, body: []const u8) FailureClass {
    if (hasPermanentErrorCode(body)) return .permanent;
    const value = status orelse return .transient;
    if (value == 429 or value >= 500) return .transient;
    if (value == 400 or value == 401 or value == 403) return .protocol;
    return if (value >= 400) .protocol else .transient;
}

fn hasPermanentErrorCode(body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    if (obj.get("error")) |value| switch (value) {
        .string => |text| return isPermanentCode(text),
        .object => |nested| if (nested.get("code")) |code| switch (code) {
            .string => |text| return isPermanentCode(text),
            else => {},
        },
        else => {},
    };
    if (obj.get("code")) |value| switch (value) {
        .string => |text| return isPermanentCode(text),
        else => {},
    };
    return false;
}

fn isPermanentCode(value: []const u8) bool {
    return std.mem.eql(u8, value, "invalid_grant") or
        std.mem.eql(u8, value, "refresh_token_expired") or
        std.mem.eql(u8, value, "refresh_token_reused") or
        std.mem.eql(u8, value, "refresh_token_invalidated");
}

pub fn shouldRefreshAuthData(allocator: std.mem.Allocator, data: []const u8, now_seconds: i64) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const tokens = switch (obj.get("tokens") orelse return false) {
        .object => |value| value,
        else => return false,
    };
    const access = switch (tokens.get("access_token") orelse return fallbackStale(obj, now_seconds)) {
        .string => |value| value,
        else => return fallbackStale(obj, now_seconds),
    };
    const payload = auth.decodeJwtPayload(allocator, access) catch return fallbackStale(obj, now_seconds);
    defer allocator.free(payload);
    var claims = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return fallbackStale(obj, now_seconds);
    defer claims.deinit();
    const claims_obj = switch (claims.value) {
        .object => |value| value,
        else => return fallbackStale(obj, now_seconds),
    };
    const exp = switch (claims_obj.get("exp") orelse return fallbackStale(obj, now_seconds)) {
        .integer => |value| value,
        .float => |value| @as(i64, @intFromFloat(value)),
        else => return fallbackStale(obj, now_seconds),
    };
    return exp <= now_seconds + refresh_window_seconds;
}

fn fallbackStale(obj: std.json.ObjectMap, now_seconds: i64) bool {
    const value = obj.get("last_refresh") orelse return true;
    const text = switch (value) {
        .string => |s| s,
        else => return true,
    };
    const refreshed = parseTimestampSeconds(text) orelse return true;
    return now_seconds - refreshed >= fallback_max_age_seconds;
}

pub fn refreshAccount(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8, active: bool, force: bool) !Outcome {
    try registry.ensureAccountsDir(allocator, codex_home);
    const file_key = try registry.accountFileKey(allocator, account_key);
    defer allocator.free(file_key);
    const lock_name = try std.fmt.allocPrint(allocator, "{s}.refresh.lock", .{file_key});
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ codex_home, "accounts", lock_name });
    defer allocator.free(lock_path);
    const snapshot_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(snapshot_path);
    const observed = try readFile(allocator, snapshot_path);
    defer allocator.free(observed);
    var lock_file = try std.Io.Dir.cwd().createFile(app_runtime.io(), lock_path, .{ .truncate = false, .permissions = sensitive_file.permissions });
    defer lock_file.close(app_runtime.io());
    lock_file.lock(app_runtime.io(), .exclusive) catch |err| switch (err) {
        error.FileLocksUnsupported => return error.RefreshLockUnsupported,
        else => return err,
    };
    defer lock_file.unlock(app_runtime.io());

    const before = try readFile(allocator, snapshot_path);
    defer allocator.free(before);
    if (!std.mem.eql(u8, observed, before)) return .fresh;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (!force and !shouldRefreshAuthData(allocator, before, now)) return .fresh;

    const updated = try requestAndApply(allocator, before, now);
    defer allocator.free(updated);
    if (active and try activeAuthMatchesAccount(allocator, codex_home, account_key)) {
        const active_path = try registry.activeAuthPath(allocator, codex_home);
        defer allocator.free(active_path);
        try sensitive_file.writeAtomic(active_path, updated);
    }
    try sensitive_file.writeAtomic(snapshot_path, updated);
    return .refreshed;
}

fn activeAuthMatchesAccount(allocator: std.mem.Allocator, codex_home: []const u8, account_key: []const u8) !bool {
    const active_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(active_path);
    const active_data = readFile(allocator, active_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(active_data);
    const info = auth.parseAuthInfoData(allocator, active_data) catch return false;
    defer info.deinit(allocator);
    const record_key = info.record_key orelse return false;
    return std.mem.eql(u8, record_key, account_key);
}

fn requestAndApply(allocator: std.mem.Allocator, data: []const u8, now: i64) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAuthJson,
    };
    const tokens = switch (obj.get("tokens") orelse return error.MissingTokens) {
        .object => |value| value,
        else => return error.MissingTokens,
    };
    const refresh_token = switch (tokens.get("refresh_token") orelse return error.MissingRefreshToken) {
        .string => |value| value,
        else => return error.MissingRefreshToken,
    };

    var request_writer: std.Io.Writer.Allocating = .init(allocator);
    defer request_writer.deinit();
    try std.json.Stringify.value(.{ .client_id = client_id, .grant_type = "refresh_token", .refresh_token = refresh_token }, .{}, &request_writer.writer);
    const response = http.runPostJsonCommand(allocator, token_endpoint, request_writer.written()) catch |err| switch (err) {
        error.TimedOut, error.RequestFailed => return error.RefreshTransient,
        else => return err,
    };
    defer allocator.free(response.body);
    if (response.status_code == null or response.status_code.? < 200 or response.status_code.? >= 300) {
        return switch (classifyFailure(response.status_code, response.body)) {
            .permanent => error.RefreshLoginRequired,
            .protocol => error.RefreshProtocolFailure,
            .transient => error.RefreshTransient,
        };
    }
    return try applyRefreshResponse(allocator, data, response.body, now);
}

pub fn applyRefreshResponse(allocator: std.mem.Allocator, data: []const u8, response_body: []const u8, now: i64) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthJson;
    const obj = &parsed.value.object;
    const tokens_value = obj.getPtr("tokens") orelse return error.MissingTokens;
    if (tokens_value.* != .object) return error.MissingTokens;
    const tokens = &tokens_value.object;
    var response_json = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer response_json.deinit();
    const response_obj = switch (response_json.value) {
        .object => |value| value,
        else => return error.InvalidRefreshResponse,
    };
    inline for (.{ "id_token", "access_token", "refresh_token" }) |field| {
        if (response_obj.get(field)) |value| switch (value) {
            .string => try tokens.put(allocator, field, value),
            else => return error.InvalidRefreshResponse,
        };
    }
    const timestamp = try formatTimestamp(allocator, now);
    defer allocator.free(timestamp);
    try obj.put(allocator, "last_refresh", .{ .string = timestamp });
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(app_runtime.io(), path, .{});
    defer file.close(app_runtime.io());
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(app_runtime.io(), &buffer);
    return try reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
}

fn formatTimestamp(allocator: std.mem.Allocator, seconds: i64) ![]u8 {
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,                 month_day.month.numeric(),        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute(),
    });
}

fn parseTimestampSeconds(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else 0);
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const yoe = adjusted_year - era * 400;
    const mp = month + (if (month > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const days = era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
    return (((days * 24) + hour) * 60 + minute) * 60 + second;
}
