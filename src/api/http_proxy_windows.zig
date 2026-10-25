//! Windows WinINET proxy settings, read straight from the registry.
//!
//! `WinHttpGetIEProxyConfigForCurrentUser` would return the same values but
//! requires a `winhttp` import library; `RegGetValueW` from `advapi32` is the
//! same data with no extra child process and no PAC evaluation. Callers treat a
//! missing or unreadable key as "no system proxy".

const std = @import("std");
const win = std.os.windows;

const HKEY = win.HKEY;
const LONG = win.LONG;
const DWORD = win.DWORD;
const LPCWSTR = ?[*:0]const u16;

const RRF_RT_REG_SZ: DWORD = 0x0000_0002;
const RRF_RT_REG_DWORD: DWORD = 0x0000_0010;
const RRF_SUBKEY_WOW6464KEY: DWORD = 0x0001_0000;
const ERROR_SUCCESS: LONG = 0;
const ERROR_FILE_NOT_FOUND: LONG = 2;
const ERROR_PATH_NOT_FOUND: LONG = 3;

const internet_settings_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

extern "advapi32" fn RegGetValueW(
    hkey: ?HKEY,
    sub_key: LPCWSTR,
    value: LPCWSTR,
    flags: DWORD,
    rrtype: ?*DWORD,
    pvdata: ?*anyopaque,
    pcbdata: *DWORD,
) callconv(.winapi) LONG;

pub const Values = struct {
    enabled: bool = false,
    server: ?[]const u8 = null,
    bypass: ?[]const u8 = null,
};

/// Reads `ProxyEnable`, `ProxyServer`, and `ProxyOverride` for the current user.
/// All strings are allocated with `allocator` and are expected to outlive the
/// process, because the caller caches the result.
pub fn read(allocator: std.mem.Allocator) !Values {
    const sub_key = try wideAlloc(allocator, internet_settings_key);
    defer allocator.free(sub_key);

    const enable = try readDword(allocator, sub_key, "ProxyEnable");
    if (enable == null or enable.? == 0) return .{};

    return Values{
        .enabled = true,
        .server = try readString(allocator, sub_key, "ProxyServer"),
        .bypass = try readString(allocator, sub_key, "ProxyOverride"),
    };
}

fn readDword(allocator: std.mem.Allocator, sub_key: [:0]const u16, name: []const u8) !?u32 {
    var value: u32 = 0;
    var size: DWORD = @sizeOf(u32);
    var kind: DWORD = 0;
    const name_w = try wideAlloc(allocator, name);
    defer allocator.free(name_w);

    const result = RegGetValueW(
        win.HKEY_CURRENT_USER,
        sub_key.ptr,
        name_w.ptr,
        RRF_RT_REG_DWORD | RRF_SUBKEY_WOW6464KEY,
        &kind,
        @ptrCast(&value),
        &size,
    );
    if (isNotFound(result)) return null;
    if (result != ERROR_SUCCESS) return error.Win32;
    return value;
}

fn readString(allocator: std.mem.Allocator, sub_key: [:0]const u16, name: []const u8) !?[]const u8 {
    const name_w = try wideAlloc(allocator, name);
    defer allocator.free(name_w);

    var size: DWORD = 0;
    var kind: DWORD = 0;
    var probe = RegGetValueW(
        win.HKEY_CURRENT_USER,
        sub_key.ptr,
        name_w.ptr,
        RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
        &kind,
        null,
        &size,
    );
    if (isNotFound(probe)) return null;
    if (probe != ERROR_SUCCESS) return error.Win32;
    if (size < @sizeOf(u16) * 2) return null;

    const units = try allocator.alloc(u16, size / @sizeOf(u16));
    defer allocator.free(units);
    probe = RegGetValueW(
        win.HKEY_CURRENT_USER,
        sub_key.ptr,
        name_w.ptr,
        RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
        &kind,
        @ptrCast(units.ptr),
        &size,
    );
    if (isNotFound(probe)) return null;
    if (probe != ERROR_SUCCESS) return error.Win32;
    if (size < @sizeOf(u16) * 2) return null;

    // Drop the UTF-16 NUL terminator.
    return try std.unicode.wtf16LeToWtf8Alloc(allocator, units[0 .. size / @sizeOf(u16) - 1]);
}

fn isNotFound(result: LONG) bool {
    return result == ERROR_FILE_NOT_FOUND or result == ERROR_PATH_NOT_FOUND;
}

fn wideAlloc(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return try std.unicode.wtf8ToWtf16LeAllocZ(allocator, text);
}
