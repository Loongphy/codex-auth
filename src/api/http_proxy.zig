//! Proxy selection for the `curl` child process.
//!
//! `curl` discovers proxies only through its own environment variables. The
//! system proxy that a browser or PowerShell honours lives in platform settings
//! `curl` never reads, so on a machine routed through a local forwarder such as
//! mihomo the request connects directly and stalls until `--max-time` expires.
//! This module translates the platform settings into explicit `curl` options.
//!
//! Decision order:
//!
//! 1. Proxy environment variables already present — `curl` handles those itself,
//!    together with `NO_PROXY`, so nothing is injected and the behaviour of
//!    every user who already exports them is unchanged.
//! 2. The platform system proxy — injected as the `proxy` and `noproxy` curl
//!    config options.
//! 3. Nothing — a direct connection, which is the pre-existing behaviour.

const builtin = @import("builtin");
const std = @import("std");
const env = @import("http_env.zig");

const no_system_proxy = struct {
    pub const Values = struct {
        server: ?[]const u8 = null,
        bypass: ?[]const u8 = null,
    };

    pub fn read(_: std.mem.Allocator, _: []const u8) !Values {
        return .{};
    }
};

/// Linux has no system-wide proxy setting that CLI tools read; the environment
/// variables are the convention, so the `else` arm above stays empty there.
const platform = switch (builtin.os.tag) {
    .windows => @import("http_proxy_windows.zig"),
    .macos => @import("http_proxy_macos.zig"),
    else => no_system_proxy,
};

pub const Scheme = enum { http, https };

pub const Proxy = struct {
    url: []u8,
    noproxy: ?[]u8,

    pub fn deinit(self: *Proxy, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.noproxy) |noproxy| allocator.free(noproxy);
        self.* = undefined;
    }
};

/// Platform proxy settings, expressed in the shared `server`/`bypass` format
/// regardless of where they came from.
pub const SystemProxy = struct {
    /// Either a bare `host:port`, meaning one proxy for every protocol, or a
    /// per-protocol list such as `http=127.0.0.1:7890;socks=127.0.0.1:7891`.
    server: ?[]const u8 = null,
    /// Bypass list. `;` and `,` are both accepted as separators.
    bypass: ?[]const u8 = null,
};

const no_proxy_env_keys = [_][]const u8{ "NO_PROXY", "no_proxy" };

/// A proxy entry selected for one scheme.
pub const Picked = struct {
    hostport: []const u8,
    /// `curl` needs an explicit scheme to treat an entry as SOCKS; `socks5h`
    /// keeps DNS resolution on the proxy side.
    socks: bool,
};

/// Resolve the proxy to use for `endpoint` in this process.
pub fn resolve(allocator: std.mem.Allocator, endpoint: []const u8) !?Proxy {
    var env_map = try env.getEnvMap(allocator);
    defer env_map.deinit();
    return decide(allocator, &env_map, systemProxy(endpoint), schemeOf(endpoint));
}

pub fn schemeOf(endpoint: []const u8) Scheme {
    if (std.ascii.startsWithIgnoreCase(endpoint, "https://")) return .https;
    return .http;
}

/// `curl` only looks at these environment variables for a given scheme.
pub fn proxyEnvKeys(scheme: Scheme) []const []const u8 {
    return switch (scheme) {
        .https => &[_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" },
        .http => &[_][]const u8{ "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy" },
    };
}

/// Pure decision function, so the precedence rules stay testable on every
/// platform without touching WinHTTP, `scutil`, or the process environment.
pub fn decide(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    system: SystemProxy,
    scheme: Scheme,
) !?Proxy {
    for (proxyEnvKeys(scheme)) |key| {
        if (envValue(env_map, key) != null) return null;
    }

    const server = system.server orelse return null;
    const picked = pickProxyServer(scheme, server) orelse return null;

    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(allocator);
    if (picked.socks) try url.appendSlice(allocator, "socks5h://");
    try url.appendSlice(allocator, picked.hostport);

    return Proxy{
        .url = try url.toOwnedSlice(allocator),
        .noproxy = try noproxyValue(allocator, env_map, system.bypass),
    };
}

/// Exclusion list for `noproxy`: an explicit `NO_PROXY` wins over the platform
/// bypass list, because it is the user's own current intent.
fn noproxyValue(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    platform_bypass: ?[]const u8,
) !?[]u8 {
    if (noProxyEnvValue(env_map)) |from_env| return try allocator.dupe(u8, from_env);
    const bypass = platform_bypass orelse return null;
    return try translateBypass(allocator, bypass);
}

/// Select the entry that applies to `scheme` from a bare `host:port` or a
/// per-protocol list. An `https` endpoint falls back to the `http` entry and
/// vice versa, matching how local forwarders publish one port for both. A
/// `socks` entry is only a last resort: it carries a different wire protocol, so
/// an HTTP-family entry is the better match whenever one is configured, but a
/// SOCKS-only setup is still a working proxy.
pub fn pickProxyServer(scheme: Scheme, raw: []const u8) ?Picked {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '=') == null) return .{ .hostport = trimmed, .socks = false };

    const wanted = switch (scheme) {
        .https => "https",
        .http => "http",
    };
    var fallback: ?Picked = null;
    var socks_fallback: ?Picked = null;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |entry| {
        const item = std.mem.trim(u8, entry, " \t");
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const key = std.mem.trim(u8, item[0..eq], " \t");
        const value = std.mem.trim(u8, item[eq + 1 ..], " \t");
        if (value.len == 0) continue;
        const picked = Picked{
            .hostport = value,
            .socks = std.ascii.eqlIgnoreCase(key, "socks") or std.ascii.eqlIgnoreCase(key, "socks5"),
        };
        if (std.ascii.eqlIgnoreCase(key, wanted)) return picked;
        if (picked.socks) {
            if (socks_fallback == null) socks_fallback = picked;
        } else if (fallback == null and
            (std.ascii.eqlIgnoreCase(key, "https") or std.ascii.eqlIgnoreCase(key, "http")))
        {
            fallback = picked;
        }
    }
    return fallback orelse socks_fallback;
}

/// Translate a platform bypass list into curl's comma separated `noproxy` list.
/// The WinINET `<local>` shorthand becomes `localhost`, duplicates are dropped,
/// and empty input yields `null`.
pub fn translateBypass(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);

    var it = std.mem.splitAny(u8, raw, ";,");
    while (it.next()) |part_raw| {
        var part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "<local>") or std.ascii.eqlIgnoreCase(part, "<loopback>")) {
            part = "localhost";
        }
        if (containsEntry(seen.items, part)) continue;
        if (out.items.len != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, part);
        try seen.append(allocator, part);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn containsEntry(list: []const []const u8, entry: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, entry)) return true;
    }
    return false;
}

fn noProxyEnvValue(env_map: *const std.process.Environ.Map) ?[]const u8 {
    for (no_proxy_env_keys) |key| {
        const value = envValue(env_map, key) orelse continue;
        return value;
    }
    return null;
}

fn envValue(env_map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env_map.get(key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

var system_proxy_mutex: std.atomic.Mutex = .unlocked;
var system_proxy_cached: ?*const SystemProxy = null;

/// Platform proxy settings, read once per process. Every endpoint codex-auth
/// contacts is a public HTTPS host, so one cached read stays accurate even
/// where a PAC script could in principle return a different proxy per URL.
/// Platform failures degrade to "no system proxy" so a configuration problem
/// never turns into a request error.
pub fn systemProxy(endpoint: []const u8) SystemProxy {
    if (@atomicLoad(?*const SystemProxy, &system_proxy_cached, .acquire)) |cached| return cached.*;

    while (!system_proxy_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer system_proxy_mutex.unlock();
    if (@atomicLoad(?*const SystemProxy, &system_proxy_cached, .acquire)) |cached| return cached.*;

    const stored = std.heap.page_allocator.create(SystemProxy) catch return readSystemProxy(endpoint);
    stored.* = readSystemProxy(endpoint);
    @atomicStore(?*const SystemProxy, &system_proxy_cached, stored, .release);
    return stored.*;
}

fn readSystemProxy(endpoint: []const u8) SystemProxy {
    const values = platform.read(std.heap.page_allocator, endpoint) catch return .{};
    return .{ .server = values.server, .bypass = values.bypass };
}
