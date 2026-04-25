const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const types = @import("types.zig");
const output = @import("output.zig");
const style = @import("style.zig");

pub fn codexLoginArgs(opts: types.LoginOptions) []const []const u8 {
    return if (opts.device_auth)
        &[_][]const u8{ "codex", "login", "--device-auth" }
    else
        &[_][]const u8{ "codex", "login" };
}

fn ensureCodexLoginSucceeded(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            return error.CodexLoginFailed;
        },
        else => return error.CodexLoginFailed,
    }
}

fn writeCodexLoginLaunchFailureHint(err_name: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    try output.writeCodexLoginLaunchFailureHintTo(out, err_name, style.stderrColorEnabled());
    try out.flush();
}

pub fn runCodexLogin(opts: types.LoginOptions) !void {
    var child = std.process.spawn(app_runtime.io(), .{
        .argv = codexLoginArgs(opts),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err)) catch {};
        return err;
    };
    const term = child.wait(app_runtime.io()) catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err)) catch {};
        return err;
    };
    try ensureCodexLoginSucceeded(term);
}
