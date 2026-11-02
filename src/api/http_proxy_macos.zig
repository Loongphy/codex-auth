//! macOS system proxy settings, read through `scutil --proxy`.
//!
//! `scutil` prints the same dynamic-store dictionary that
//! `SCDynamicStoreCopyProxies` returns, so the values match what a browser or
//! `networksetup` sees. Going through the CLI keeps this module free of
//! CoreFoundation FFI, which matters because the macOS release artifacts are
//! cross-compiled from Linux, where Zig ships no SystemConfiguration stub.
//!
//! A PAC-only configuration is reported as no system proxy: evaluating the
//! script would need CFNetwork's JavaScript runner. Those setups keep working
//! through proxy environment variables.

const std = @import("std");
const child = @import("http_child.zig");
const scutil = @import("http_proxy_scutil.zig");

/// Absolute path because a GUI-launched parent can hand us a minimal `PATH`.
const scutil_path = "/usr/sbin/scutil";
const scutil_timeout_ms: u64 = 2000;
const scutil_max_output_bytes = 64 * 1024;

pub const Values = scutil.Values;

pub fn read(allocator: std.mem.Allocator, endpoint: []const u8) !Values {
    _ = endpoint;

    var result = try child.runChildCaptureWithOutputLimit(
        allocator,
        &.{ scutil_path, "--proxy" },
        scutil_timeout_ms,
        null,
        scutil_max_output_bytes,
    );
    defer result.deinit(allocator);

    if (result.timed_out) return .{};
    switch (result.term) {
        .exited => |code| if (code != 0) return .{},
        else => return .{},
    }
    return try scutil.parse(allocator, result.stdout);
}
