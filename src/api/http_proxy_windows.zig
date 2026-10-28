//! Windows system proxy settings, read through WinHTTP.
//!
//! `WinHttpGetIEProxyConfigForCurrentUser` is the documented surface for the
//! proxy a browser or PowerShell would use, and it already folds `ProxyEnable`
//! in, so a null static entry really means "no proxy" rather than "disabled
//! entry still present". When the user configured an explicit auto-config URL,
//! `WinHttpGetProxyForUrl` evaluates the PAC script in-process, so no JavaScript
//! engine is needed here.
//!
//! WPAD auto-detection is deliberately not requested: it probes DHCP and DNS and
//! can stall for seconds on a network with no WPAD server, and no local
//! forwarder such as mihomo relies on it. Callers treat any failure as "no
//! system proxy", so a configuration problem never becomes a request error.

const std = @import("std");
const win = std.os.windows;

const PWSTR = ?[*:0]u16;
const PCWSTR = ?[*:0]const u16;
const HINTERNET = ?*anyopaque;

const WINHTTP_CURRENT_USER_IE_PROXY_CONFIG = extern struct {
    fAutoDetect: win.BOOL,
    lpszAutoConfigUrl: PWSTR,
    lpszProxy: PWSTR,
    lpszProxyBypass: PWSTR,
};

const WINHTTP_AUTOPROXY_OPTIONS = extern struct {
    dwFlags: win.DWORD,
    dwAutoDetectFlags: win.DWORD,
    lpszAutoConfigUrl: PCWSTR,
    lpvReserved: ?*anyopaque,
    dwReserved: win.DWORD,
    fAutoLogonIfChallenged: win.BOOL,
};

const WINHTTP_PROXY_INFO = extern struct {
    dwAccessType: win.DWORD,
    lpszProxy: PWSTR,
    lpszProxyBypass: PWSTR,
};

const WINHTTP_ACCESS_TYPE_NO_PROXY: win.DWORD = 1;
const WINHTTP_ACCESS_TYPE_NAMED_PROXY: win.DWORD = 3;
const WINHTTP_AUTOPROXY_CONFIG_URL: win.DWORD = 0x0000_0002;

extern "winhttp" fn WinHttpGetIEProxyConfigForCurrentUser(
    config: *WINHTTP_CURRENT_USER_IE_PROXY_CONFIG,
) callconv(.winapi) win.BOOL;
extern "winhttp" fn WinHttpOpen(
    agent: PCWSTR,
    access_type: win.DWORD,
    proxy: PCWSTR,
    proxy_bypass: PCWSTR,
    flags: win.DWORD,
) callconv(.winapi) HINTERNET;
extern "winhttp" fn WinHttpCloseHandle(session: HINTERNET) callconv(.winapi) win.BOOL;
extern "winhttp" fn WinHttpGetProxyForUrl(
    session: HINTERNET,
    url: PCWSTR,
    options: *const WINHTTP_AUTOPROXY_OPTIONS,
    info: *WINHTTP_PROXY_INFO,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn GlobalFree(ptr: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const Values = struct {
    /// Proxy for every protocol, or a per-protocol list; see `http_proxy.zig`.
    server: ?[]const u8 = null,
    /// WinINET `ProxyOverride`, `;` separated.
    bypass: ?[]const u8 = null,
};

pub fn read(allocator: std.mem.Allocator, endpoint: []const u8) !Values {
    var config = WINHTTP_CURRENT_USER_IE_PROXY_CONFIG{
        .fAutoDetect = .FALSE,
        .lpszAutoConfigUrl = null,
        .lpszProxy = null,
        .lpszProxyBypass = null,
    };
    if (WinHttpGetIEProxyConfigForCurrentUser(&config) == .FALSE) return .{};
    defer freeWide(config.lpszAutoConfigUrl);
    defer freeWide(config.lpszProxy);
    defer freeWide(config.lpszProxyBypass);

    const pac_url = try wideToUtf8Alloc(allocator, config.lpszAutoConfigUrl);
    defer if (pac_url) |url| allocator.free(url);

    if (pac_url) |url| {
        // A resolved PAC answer, including "this destination is direct", wins
        // over the static entry. Only a failed lookup falls through.
        if (try readViaPac(allocator, url, endpoint)) |resolved| return resolved;
    }

    const server = try wideToUtf8Alloc(allocator, config.lpszProxy) orelse return .{};
    return Values{
        .server = server,
        .bypass = try wideToUtf8Alloc(allocator, config.lpszProxyBypass),
    };
}

/// Returns `null` when WinHTTP could not evaluate the script, so the caller can
/// still use a static proxy configured alongside it.
fn readViaPac(allocator: std.mem.Allocator, pac_url: []const u8, endpoint: []const u8) !?Values {
    const session = Session.open() orelse return null;
    defer session.close();

    const pac_url_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, pac_url);
    defer allocator.free(pac_url_w);
    const endpoint_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, endpoint);
    defer allocator.free(endpoint_w);

    const options = WINHTTP_AUTOPROXY_OPTIONS{
        .dwFlags = WINHTTP_AUTOPROXY_CONFIG_URL,
        .dwAutoDetectFlags = 0,
        .lpszAutoConfigUrl = pac_url_w.ptr,
        .lpvReserved = null,
        .dwReserved = 0,
        .fAutoLogonIfChallenged = .TRUE,
    };
    var info = WINHTTP_PROXY_INFO{
        .dwAccessType = WINHTTP_ACCESS_TYPE_NO_PROXY,
        .lpszProxy = null,
        .lpszProxyBypass = null,
    };
    if (WinHttpGetProxyForUrl(session.handle, endpoint_w.ptr, &options, &info) == .FALSE) return null;
    defer freeWide(info.lpszProxy);
    defer freeWide(info.lpszProxyBypass);

    if (info.dwAccessType == WINHTTP_ACCESS_TYPE_NO_PROXY) return Values{};
    if (info.dwAccessType != WINHTTP_ACCESS_TYPE_NAMED_PROXY) return null;

    const server = try wideToUtf8Alloc(allocator, info.lpszProxy) orelse return null;
    return Values{
        .server = server,
        .bypass = try wideToUtf8Alloc(allocator, info.lpszProxyBypass),
    };
}

/// An auto-proxy session must not inherit a static proxy of its own, otherwise
/// `WinHttpGetProxyForUrl` would answer from that instead of running the script.
const Session = struct {
    handle: HINTERNET,

    fn open() ?Session {
        const agent = std.unicode.utf8ToUtf16LeStringLiteral("codex-auth");
        const handle = WinHttpOpen(agent.ptr, WINHTTP_ACCESS_TYPE_NO_PROXY, null, null, 0);
        if (handle == null) return null;
        return .{ .handle = handle };
    }

    fn close(self: Session) void {
        _ = WinHttpCloseHandle(self.handle);
    }
};

/// WinHTTP hands back `GlobalAlloc` memory, so it must go back through
/// `GlobalFree` rather than an allocator.
fn freeWide(ptr: PWSTR) void {
    if (ptr) |value| _ = GlobalFree(@ptrCast(value));
}

fn wideToUtf8Alloc(allocator: std.mem.Allocator, ptr: PWSTR) !?[]u8 {
    const wide = ptr orelse return null;
    const length = std.mem.len(wide);
    if (length == 0) return null;
    return try std.unicode.wtf16LeToWtf8Alloc(allocator, wide[0..length]);
}
