const std = @import("std");
const auth = @import("auth.zig");
const registry = @import("registry.zig");

const opencode_accounts_file_name = "codex-accounts.json";
const opencode_auth_file_name = "auth.json";

const SnapshotTokens = struct {
    access_token: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    id_token: ?[]u8 = null,
    account_id: ?[]u8 = null,
    last_refresh: ?[]u8 = null,

    fn deinit(self: *SnapshotTokens, allocator: std.mem.Allocator) void {
        if (self.access_token) |value| allocator.free(value);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.id_token) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.last_refresh) |value| allocator.free(value);
    }
};

const AccountOut = struct {
    recordKey: []const u8,
    accountId: []const u8,
    userId: []const u8,
    email: []const u8,
    alias: []const u8,
    accountName: ?[]const u8,
    plan: ?[]const u8,
    refreshToken: ?[]const u8,
    accessToken: ?[]const u8,
    idToken: ?[]const u8,
    lastRefresh: ?[]const u8,
    enabled: bool,
    createdAt: i64,
    lastUsedAt: ?i64,
    lastUsage: ?registry.RateLimitSnapshot,
    lastUsageAt: ?i64,
};

const AccountsFileOut = struct {
    version: u32,
    activeIndex: usize,
    importedFrom: []const u8,
    importedAt: i64,
    accounts: []const AccountOut,
};

const OauthProviderOut = struct {
    type: []const u8,
    refresh: ?[]const u8,
    access: ?[]const u8,
    expires: i64,
    accountId: ?[]const u8,
};

const FreshAuthFileOut = struct {
    openai: OauthProviderOut,
    codex: OauthProviderOut,
};

const PreservedProvider = struct {
    key: []u8,
    raw_json: []u8,

    fn deinit(self: *PreservedProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.raw_json);
    }
};

const ServerEndpoint = struct {
    host: []u8,
    port: u16,

    fn deinit(self: *ServerEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
    }
};

pub fn sync(allocator: std.mem.Allocator, codex_home: []const u8, reg: *const registry.Registry) !void {
    const user_home = registry.resolveUserHome(allocator) catch |err| {
        std.log.warn("opencode sync skipped: cannot resolve user home: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(user_home);

    const config_dir = try resolveOpencodeConfigDir(allocator, user_home);
    defer allocator.free(config_dir);
    const data_dir = try resolveOpencodeDataDir(allocator, user_home);
    defer allocator.free(data_dir);

    try syncAccountsFile(allocator, codex_home, reg, config_dir);
    try syncAuthFile(allocator, codex_home, reg, data_dir);
}

pub fn refreshRunningServers(allocator: std.mem.Allocator, codex_home: []const u8, reg: *const registry.Registry) !void {
    var endpoints = discoverRunningServers(allocator) catch |err| {
        std.log.warn("opencode runtime refresh skipped: {s}", .{@errorName(err)});
        return;
    };
    defer {
        for (endpoints.items) |*endpoint| endpoint.deinit(allocator);
        endpoints.deinit(allocator);
    }
    if (endpoints.items.len == 0) return;

    const provider = try buildActiveProvider(allocator, codex_home, reg);
    defer if (provider) |*entry| {
        freeOptionalOwnedString(allocator, entry.refresh);
        freeOptionalOwnedString(allocator, entry.access);
        freeOptionalOwnedString(allocator, entry.accountId);
    };

    const active_email = activeEmail(reg);
    for (endpoints.items) |endpoint| {
        refreshServerEndpoint(allocator, endpoint, provider, active_email) catch |err| {
            std.log.warn("opencode runtime refresh failed for {s}:{d}: {s}", .{ endpoint.host, endpoint.port, @errorName(err) });
        };
    }
}

fn syncAccountsFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
    config_dir: []const u8,
) !void {
    try std.fs.cwd().makePath(config_dir);

    const registry_path = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "accounts", "registry.json" });
    defer allocator.free(registry_path);

    var accounts_out = std.ArrayList(AccountOut).empty;
    defer {
        for (accounts_out.items) |account| {
            freeOptionalOwnedString(allocator, account.plan);
            freeOptionalOwnedString(allocator, account.refreshToken);
            freeOptionalOwnedString(allocator, account.accessToken);
            freeOptionalOwnedString(allocator, account.idToken);
            freeOptionalOwnedString(allocator, account.lastRefresh);
        }
        accounts_out.deinit(allocator);
    }

    var active_index: usize = 0;
    var active_found = false;

    for (reg.accounts.items) |rec| {
        const auth_path = registry.accountAuthPath(allocator, codex_home, rec.account_key) catch |err| {
            std.log.warn("opencode account export skipped for {s}: {s}", .{ rec.email, @errorName(err) });
            continue;
        };
        defer allocator.free(auth_path);

        var tokens = readSnapshotTokens(allocator, auth_path) catch |err| {
            std.log.warn("opencode account export skipped for {s}: {s}", .{ rec.email, @errorName(err) });
            continue;
        };
        defer tokens.deinit(allocator);

        const plan = if (registry.resolvePlan(&rec)) |value|
            try allocator.dupe(u8, planTypeLabel(value))
        else
            null;
        errdefer freeOptionalOwnedString(allocator, plan);

        try accounts_out.append(allocator, .{
            .recordKey = rec.account_key,
            .accountId = rec.chatgpt_account_id,
            .userId = rec.chatgpt_user_id,
            .email = rec.email,
            .alias = rec.alias,
            .accountName = rec.account_name,
            .plan = plan,
            .refreshToken = try cloneOptionalString(allocator, tokens.refresh_token),
            .accessToken = try cloneOptionalString(allocator, tokens.access_token),
            .idToken = try cloneOptionalString(allocator, tokens.id_token),
            .lastRefresh = try cloneOptionalString(allocator, tokens.last_refresh),
            .enabled = true,
            .createdAt = rec.created_at,
            .lastUsedAt = rec.last_used_at,
            .lastUsage = rec.last_usage,
            .lastUsageAt = rec.last_usage_at,
        });

        if (!active_found) {
            if (reg.active_account_key) |active_key| {
                if (std.mem.eql(u8, active_key, rec.account_key)) {
                    active_index = accounts_out.items.len - 1;
                    active_found = true;
                }
            }
        }
    }

    if (!active_found) active_index = 0;

    const out = AccountsFileOut{
        .version = 1,
        .activeIndex = if (accounts_out.items.len == 0) 0 else @min(active_index, accounts_out.items.len - 1),
        .importedFrom = registry_path,
        .importedAt = std.time.milliTimestamp(),
        .accounts = accounts_out.items,
    };

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, &writer.writer);

    const path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, opencode_accounts_file_name });
    defer allocator.free(path);
    try writeFileIfChanged(path, writer.written());
}

fn syncAuthFile(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
    data_dir: []const u8,
) !void {
    try std.fs.cwd().makePath(data_dir);

    const path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, opencode_auth_file_name });
    defer allocator.free(path);

    const provider = try buildActiveProvider(allocator, codex_home, reg);
    defer if (provider) |*entry| {
        freeOptionalOwnedString(allocator, entry.refresh);
        freeOptionalOwnedString(allocator, entry.access);
        freeOptionalOwnedString(allocator, entry.accountId);
    };

    const existing = try readFileIfExists(allocator, path);
    defer if (existing) |bytes| allocator.free(bytes);

    var preserved = std.ArrayList(PreservedProvider).empty;
    defer {
        for (preserved.items) |*item| item.deinit(allocator);
        preserved.deinit(allocator);
    }

    if (existing) |bytes| {
        try loadPreservedProviders(allocator, bytes, &preserved);
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writeAuthFile(&writer.writer, preserved.items, provider);
    try writeFileIfChanged(path, writer.written());
}

fn buildActiveProvider(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    reg: *const registry.Registry,
) !?OauthProviderOut {
    const active_key = reg.active_account_key orelse return null;
    const active_idx = registry.findAccountIndexByAccountKey(@constCast(reg), active_key) orelse return null;
    const active = reg.accounts.items[active_idx];
    if (active.auth_mode != null and active.auth_mode.? != .chatgpt) return null;

    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    var tokens = readSnapshotTokens(allocator, auth_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer tokens.deinit(allocator);

    const refresh_token = tokens.refresh_token orelse return null;
    const access_token = tokens.access_token orelse return null;

    const expires = accessTokenExpiryMs(allocator, access_token) catch 0;

    return .{
        .type = "oauth",
        .refresh = try allocator.dupe(u8, refresh_token),
        .access = try allocator.dupe(u8, access_token),
        .expires = expires,
        .accountId = if (tokens.account_id) |account_id|
            try allocator.dupe(u8, account_id)
        else
            try allocator.dupe(u8, active.chatgpt_account_id),
    };
}

fn readSnapshotTokens(allocator: std.mem.Allocator, auth_path: []const u8) !SnapshotTokens {
    const data = try readFileAlloc(allocator, auth_path);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.MalformedJson,
    };

    const tokens_obj = switch (root_obj.get("tokens") orelse return .{}) {
        .object => |obj| obj,
        else => return .{},
    };

    return .{
        .access_token = try dupJsonStringField(allocator, tokens_obj, "access_token"),
        .refresh_token = try dupJsonStringField(allocator, tokens_obj, "refresh_token"),
        .id_token = try dupJsonStringField(allocator, tokens_obj, "id_token"),
        .account_id = try dupJsonStringField(allocator, tokens_obj, "account_id"),
        .last_refresh = try dupJsonStringField(allocator, root_obj, "last_refresh"),
    };
}

fn dupJsonStringField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else try allocator.dupe(u8, text),
        else => null,
    };
}

fn accessTokenExpiryMs(allocator: std.mem.Allocator, access_token: []const u8) !i64 {
    const payload = try auth.decodeJwtPayload(allocator, access_token);
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const payload_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidJwt,
    };
    const exp_value = payload_obj.get("exp") orelse return error.InvalidJwt;
    const exp_seconds = switch (exp_value) {
        .integer => |value| value,
        .string => |value| try std.fmt.parseInt(i64, value, 10),
        else => return error.InvalidJwt,
    };
    return exp_seconds * std.time.ms_per_s;
}

fn resolveOpencodeConfigDir(allocator: std.mem.Allocator, user_home: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        if (try getNonEmptyEnvVarOwned(allocator, "APPDATA")) |app_data| return std.fs.path.join(allocator, &[_][]const u8{ app_data, "opencode" });
        return std.fs.path.join(allocator, &[_][]const u8{ user_home, "AppData", "Roaming", "opencode" });
    }

    if (try getNonEmptyEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &[_][]const u8{ xdg, "opencode" });
    }
    return std.fs.path.join(allocator, &[_][]const u8{ user_home, ".config", "opencode" });
}

fn resolveOpencodeDataDir(allocator: std.mem.Allocator, user_home: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        if (try getNonEmptyEnvVarOwned(allocator, "APPDATA")) |app_data| return std.fs.path.join(allocator, &[_][]const u8{ app_data, "opencode" });
        return std.fs.path.join(allocator, &[_][]const u8{ user_home, "AppData", "Roaming", "opencode" });
    }

    if (try getNonEmptyEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &[_][]const u8{ xdg, "opencode" });
    }
    return std.fs.path.join(allocator, &[_][]const u8{ user_home, ".local", "share", "opencode" });
}

fn getNonEmptyEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn readFileIfExists(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn writeFileIfChanged(path: []const u8, data: []const u8) !void {
    const existing = try readFileIfExists(std.heap.page_allocator, path);
    defer if (existing) |bytes| std.heap.page_allocator.free(bytes);
    if (existing) |bytes| {
        if (std.mem.eql(u8, bytes, data)) return;
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeOptionalOwnedString(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |text| allocator.free(@constCast(text));
}

fn planTypeLabel(plan: registry.PlanType) []const u8 {
    return switch (plan) {
        .free => "free",
        .plus => "plus",
        .pro => "pro",
        .team => "team",
        .business => "business",
        .enterprise => "enterprise",
        .edu => "edu",
        .unknown => "unknown",
    };
}

fn loadPreservedProviders(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    preserved: *std.ArrayList(PreservedProvider),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        std.log.warn("opencode auth sync skipped: cannot parse existing auth.json: {s}", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.log.warn("opencode auth sync skipped: auth.json root must be an object", .{});
            return;
        },
    };

    var it = root.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "openai") or std.mem.eql(u8, entry.key_ptr.*, "codex")) continue;
        var value_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer value_writer.deinit();
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &value_writer.writer);
        try preserved.append(allocator, .{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .raw_json = try value_writer.toOwnedSlice(),
        });
    }
}

fn writeAuthFile(
    writer: *std.Io.Writer,
    preserved: []const PreservedProvider,
    provider: ?OauthProviderOut,
) !void {
    try writer.writeAll("{\n");
    var wrote_any = false;
    for (preserved) |entry| {
        if (wrote_any) try writer.writeAll(",\n");
        try writeJsonString(writer, entry.key);
        try writer.writeAll(": ");
        try writer.writeAll(entry.raw_json);
        wrote_any = true;
    }

    if (provider) |oauth| {
        if (wrote_any) try writer.writeAll(",\n");
        try writeJsonString(writer, "openai");
        try writer.writeAll(": ");
        try std.json.Stringify.value(oauth, .{ .whitespace = .indent_2 }, writer);
        try writer.writeAll(",\n");
        try writeJsonString(writer, "codex");
        try writer.writeAll(": ");
        try std.json.Stringify.value(oauth, .{ .whitespace = .indent_2 }, writer);
        wrote_any = true;
    }

    if (wrote_any) try writer.writeAll("\n");
    try writer.writeAll("}\n");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn activeEmail(reg: *const registry.Registry) ?[]const u8 {
    const active_key = reg.active_account_key orelse return null;
    const idx = registry.findAccountIndexByAccountKey(@constCast(reg), active_key) orelse return null;
    return reg.accounts.items[idx].email;
}

fn discoverRunningServers(allocator: std.mem.Allocator) !std.ArrayList(ServerEndpoint) {
    if (@import("builtin").os.tag == .windows) return .empty;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN" },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }

    var servers = std.ArrayList(ServerEndpoint).empty;
    errdefer {
        for (servers.items) |*server| server.deinit(allocator);
        servers.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        const parsed = parseLsofServerLine(allocator, line) orelse continue;
        if (containsServer(servers.items, parsed.host, parsed.port)) {
            var dup = parsed;
            dup.deinit(allocator);
            continue;
        }
        try servers.append(allocator, parsed);
    }
    return servers;
}

fn parseLsofServerLine(allocator: std.mem.Allocator, line: []const u8) ?ServerEndpoint {
    if (line.len == 0) return null;

    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const command = fields.next() orelse return null;
    if (!std.mem.eql(u8, command, "opencode")) return null;

    const tcp_idx = std.mem.indexOf(u8, line, "TCP ") orelse return null;
    const addr_start = tcp_idx + 4;
    const addr_end = std.mem.indexOfScalarPos(u8, line, addr_start, ' ') orelse return null;
    const address = line[addr_start..addr_end];

    const colon_idx = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    const host = address[0..colon_idx];
    if (!(std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost"))) return null;
    const port = std.fmt.parseInt(u16, address[colon_idx + 1 ..], 10) catch return null;

    return .{
        .host = allocator.dupe(u8, host) catch return null,
        .port = port,
    };
}

fn containsServer(servers: []const ServerEndpoint, host: []const u8, port: u16) bool {
    for (servers) |server| {
        if (server.port == port and std.mem.eql(u8, server.host, host)) return true;
    }
    return false;
}

fn refreshServerEndpoint(
    allocator: std.mem.Allocator,
    endpoint: ServerEndpoint,
    provider: ?OauthProviderOut,
    active_email: ?[]const u8,
) !void {
    const base_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ endpoint.host, endpoint.port });
    defer allocator.free(base_url);

    if (provider) |entry| {
        var auth_writer: std.Io.Writer.Allocating = .init(allocator);
        defer auth_writer.deinit();
        try std.json.Stringify.value(entry, .{}, &auth_writer.writer);

        const auth_url = try std.fmt.allocPrint(allocator, "{s}/auth/openai", .{base_url});
        defer allocator.free(auth_url);
        try postJsonExpectTrue(allocator, .PUT, auth_url, auth_writer.written());

        const message = if (active_email) |email|
            try std.fmt.allocPrint(allocator, "Codex OAuth switched to {s}", .{email})
        else
            try allocator.dupe(u8, "Codex OAuth refreshed");
        defer allocator.free(message);

        try showToast(allocator, base_url, "codex-auth", message, "success", 4000);
        return;
    }

    const auth_url = try std.fmt.allocPrint(allocator, "{s}/auth/openai", .{base_url});
    defer allocator.free(auth_url);
    try deleteExpectTrue(allocator, auth_url);
    try showToast(allocator, base_url, "codex-auth", "Codex OAuth removed", "info", 4000);
}

fn showToast(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    title: []const u8,
    message: []const u8,
    variant: []const u8,
    duration_ms: u32,
) !void {
    const toast_url = try std.fmt.allocPrint(allocator, "{s}/tui/show-toast", .{base_url});
    defer allocator.free(toast_url);

    const ToastPayload = struct {
        title: []const u8,
        message: []const u8,
        variant: []const u8,
        duration: u32,
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(ToastPayload{
        .title = title,
        .message = message,
        .variant = variant,
        .duration = duration_ms,
    }, .{}, &writer.writer);
    try postJsonExpectTrue(allocator, .POST, toast_url, writer.written());
}

fn postJsonExpectTrue(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: []const u8,
) !void {
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = &headers,
        .response_writer = &response.writer,
    });
    if (result.status != .ok) return error.RequestFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, response.written(), " \n\r\t"), "true")) return error.RequestFailed;
}

fn deleteExpectTrue(allocator: std.mem.Allocator, url: []const u8) !void {
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .DELETE,
        .response_writer = &response.writer,
    });
    if (result.status != .ok) return error.RequestFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, response.written(), " \n\r\t"), "true")) return error.RequestFailed;
}

test "parse lsof server line extracts opencode localhost listener" {
    const gpa = std.testing.allocator;
    const line = "opencode  70079 jyuny1   13u  IPv4 0xb71f5b3dfd3e9e93      0t0  TCP 127.0.0.1:4096 (LISTEN)";
    var parsed = parseLsofServerLine(gpa, line).?;
    defer parsed.deinit(gpa);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 4096), parsed.port);
}

test "parse lsof server line ignores non-opencode listeners" {
    const line = "Google 33616 jyuny1 127u IPv4 0x631855f26dc52fa8 0t0 TCP 127.0.0.1:9222 (LISTEN)";
    try std.testing.expect(parseLsofServerLine(std.testing.allocator, line) == null);
}
