const builtin = @import("builtin");
const std = @import("std");
const winreg = if (builtin.os.tag == .windows) struct {
    extern "advapi32" fn RegGetValueW(
        hkey: std.os.windows.HKEY,
        sub_key: ?[*:0]const u16,
        value_name: ?[*:0]const u16,
        flags: u32,
        actual_type: ?*std.os.windows.ULONG,
        data: ?*anyopaque,
        data_len: ?*u32,
    ) callconv(.winapi) std.os.windows.LSTATUS;

    const RRF_RT_REG_SZ: u32 = 0x00000002;
    const RRF_RT_REG_EXPAND_SZ: u32 = 0x00000004;
    const RRF_RT_REG_DWORD: u32 = 0x00000010;
} else struct {};

pub fn maybeConfigureCurlProxy(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) !void {
    try maybeMapAllProxy(env_map);
    try maybeApplyWindowsSystemProxyFallback(allocator, env_map);
}

fn hasAllProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("ALL_PROXY") != null or env_map.get("all_proxy") != null;
}

fn maybeMapAllProxy(env_map: *std.process.Environ.Map) !void {
    const all_proxy = env_map.get("ALL_PROXY") orelse env_map.get("all_proxy");
    if (all_proxy) |proxy| {
        if (env_map.get("HTTP_PROXY") == null and env_map.get("http_proxy") == null) {
            try env_map.put("HTTP_PROXY", proxy);
        }
        if (env_map.get("HTTPS_PROXY") == null and env_map.get("https_proxy") == null) {
            try env_map.put("HTTPS_PROXY", proxy);
        }
    }
}

fn hasDirectProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("HTTP_PROXY") != null or
        env_map.get("http_proxy") != null or
        env_map.get("HTTPS_PROXY") != null or
        env_map.get("https_proxy") != null;
}

fn hasNoProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("NO_PROXY") != null or env_map.get("no_proxy") != null;
}

const windows_internet_settings_key = std.unicode.wtf8ToWtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings");
const windows_proxy_enable_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyEnable");
const windows_proxy_server_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyServer");
const windows_proxy_override_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyOverride");

pub const WindowsSystemProxy = struct {
    http_proxy: ?[]u8 = null,
    https_proxy: ?[]u8 = null,
    no_proxy: ?[]u8 = null,

    pub fn deinit(self: *WindowsSystemProxy, allocator: std.mem.Allocator) void {
        if (self.http_proxy) |value| allocator.free(value);
        if (self.https_proxy) |value| allocator.free(value);
        if (self.no_proxy) |value| allocator.free(value);
        self.* = .{};
    }
};

pub fn maybeApplyWindowsSystemProxyFallback(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    if (builtin.os.tag != .windows) return;
    if (hasDirectProxyConfiguration(env_map)) return;

    var proxy = (try queryWindowsSystemProxyAlloc(allocator)) orelse return;
    defer proxy.deinit(allocator);

    if (proxy.http_proxy) |value| {
        if (env_map.get("HTTP_PROXY") == null and env_map.get("http_proxy") == null) {
            try env_map.put("HTTP_PROXY", value);
        }
    }
    if (proxy.https_proxy) |value| {
        if (env_map.get("HTTPS_PROXY") == null and env_map.get("https_proxy") == null) {
            try env_map.put("HTTPS_PROXY", value);
        }
    }
    if (proxy.no_proxy) |value| {
        if (!hasNoProxyConfiguration(env_map)) {
            try env_map.put("NO_PROXY", value);
        }
    }
}

fn queryWindowsSystemProxyAlloc(allocator: std.mem.Allocator) !?WindowsSystemProxy {
    if (builtin.os.tag != .windows) return null;

    const proxy_enabled = readWindowsRegistryDword(
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_enable_value,
    ) catch return null;
    if (proxy_enabled == 0) return null;

    const proxy_server = readWindowsRegistryStringAlloc(
        allocator,
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_server_value,
    ) catch |err| switch (err) {
        error.ValueNotFound, error.UnexpectedRegistryType, error.RegistryReadFailed => return null,
        else => return err,
    };
    defer allocator.free(proxy_server);

    const proxy_override = readWindowsRegistryStringAlloc(
        allocator,
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_override_value,
    ) catch |err| switch (err) {
        error.ValueNotFound, error.UnexpectedRegistryType, error.RegistryReadFailed => null,
        else => return err,
    };
    defer if (proxy_override) |value| allocator.free(value);

    return try deriveWindowsSystemProxyAlloc(allocator, proxy_server, proxy_override);
}

pub fn deriveWindowsSystemProxyAlloc(
    allocator: std.mem.Allocator,
    proxy_server_raw: []const u8,
    proxy_override_raw: ?[]const u8,
) !?WindowsSystemProxy {
    const proxy_server = std.mem.trim(u8, proxy_server_raw, " \t\r\n");
    if (proxy_server.len == 0) return null;

    var result = WindowsSystemProxy{};
    errdefer result.deinit(allocator);

    var default_proxy: ?[]u8 = null;
    defer if (default_proxy) |value| allocator.free(value);

    var entries = std.mem.splitScalar(u8, proxy_server, ';');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;

        if (std.mem.indexOfScalar(u8, entry, '=')) |eq_idx| {
            const key = std.mem.trim(u8, entry[0..eq_idx], " \t\r\n");
            const value = std.mem.trim(u8, entry[eq_idx + 1 ..], " \t\r\n");
            if (value.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(key, "http")) {
                if (result.http_proxy == null) result.http_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "http://");
            } else if (std.ascii.eqlIgnoreCase(key, "https")) {
                if (result.https_proxy == null) result.https_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "http://");
            } else if (std.ascii.eqlIgnoreCase(key, "socks")) {
                const socks_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "socks://");
                defer allocator.free(socks_proxy);
                if (result.http_proxy == null) result.http_proxy = try allocator.dupe(u8, socks_proxy);
                if (result.https_proxy == null) result.https_proxy = try allocator.dupe(u8, socks_proxy);
            }
        } else if (default_proxy == null) {
            default_proxy = try normalizeWindowsProxyUrlAlloc(allocator, entry, "http://");
        }
    }

    if (default_proxy) |value| {
        if (result.http_proxy == null) result.http_proxy = try allocator.dupe(u8, value);
        if (result.https_proxy == null) result.https_proxy = try allocator.dupe(u8, value);
    }

    if (result.http_proxy == null and result.https_proxy == null) return null;

    if (proxy_override_raw) |raw| {
        result.no_proxy = try normalizeWindowsNoProxyAlloc(allocator, raw);
    }

    return result;
}

fn normalizeWindowsProxyUrlAlloc(allocator: std.mem.Allocator, raw: []const u8, default_scheme: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, trimmed);
    if (std.mem.indexOf(u8, trimmed, "://") != null) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ default_scheme, trimmed });
}

fn normalizeWindowsNoProxyAlloc(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    var overrides = std.mem.splitScalar(u8, raw, ';');
    while (overrides.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(entry, "<local>")) continue;
        if (entry[0] == '<' and entry[entry.len - 1] == '>') continue;
        try appendNoProxyEntry(allocator, &list, entry);
    }

    if (list.items.len == 0) return null;
    return try list.toOwnedSlice(allocator);
}

fn appendNoProxyEntry(allocator: std.mem.Allocator, list: *std.ArrayList(u8), entry: []const u8) !void {
    if (entry.len == 0) return;
    if (list.items.len != 0) try list.append(allocator, ',');
    try list.appendSlice(allocator, entry);
}

fn readWindowsRegistryDword(
    hkey: std.os.windows.HKEY,
    sub_key: [*:0]const u16,
    value_name: [*:0]const u16,
) error{ RegistryReadFailed, UnexpectedRegistryType, ValueNotFound }!u32 {
    if (builtin.os.tag != .windows) return error.ValueNotFound;

    var actual_type: std.os.windows.ULONG = undefined;
    var reg_size: u32 = @sizeOf(u32);
    var reg_value: u32 = 0;
    const rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_DWORD,
        &actual_type,
        &reg_value,
        &reg_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.DWORD)) return error.UnexpectedRegistryType;
    return reg_value;
}

fn readWindowsRegistryStringAlloc(
    allocator: std.mem.Allocator,
    hkey: std.os.windows.HKEY,
    sub_key: [*:0]const u16,
    value_name: [*:0]const u16,
) error{ OutOfMemory, RegistryReadFailed, UnexpectedRegistryType, ValueNotFound }![]u8 {
    if (builtin.os.tag != .windows) return error.ValueNotFound;

    var actual_type: std.os.windows.ULONG = undefined;
    var buf_size: u32 = 0;
    var rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_SZ | winreg.RRF_RT_REG_EXPAND_SZ,
        &actual_type,
        null,
        &buf_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.SZ) and
        actual_type != @intFromEnum(std.os.windows.REG.ValueType.EXPAND_SZ))
    {
        return error.UnexpectedRegistryType;
    }

    const buf = try allocator.alloc(u16, std.math.divCeil(u32, buf_size, 2) catch unreachable);
    defer allocator.free(buf);

    rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_SZ | winreg.RRF_RT_REG_EXPAND_SZ,
        &actual_type,
        buf.ptr,
        &buf_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.SZ) and
        actual_type != @intFromEnum(std.os.windows.REG.ValueType.EXPAND_SZ))
    {
        return error.UnexpectedRegistryType;
    }

    const value_z: [*:0]const u16 = @ptrCast(buf.ptr);
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(value_z)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryReadFailed,
    };
}
