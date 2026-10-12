const builtin = @import("builtin");
const std = @import("std");
const codex_auth = @import("codex_auth");

test {
    std.testing.refAllDecls(codex_auth);
}

fn runEntry(comptime command_line: []const u8, argv: []const [*:0]const u8, allocator: std.mem.Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    return codex_auth.workflows.main(.{
        .minimal = .{
            .args = .{ .vector = if (builtin.os.tag == .windows) std.unicode.utf8ToUtf16LeStringLiteral(command_line) else argv },
            .environ = .empty,
        },
        .arena = &arena,
        .gpa = allocator,
        .io = std.testing.io,
        .environ_map = &env_map,
        .preopens = .empty,
    });
}

test "runtime entry uses the supplied allocator and releases context on errors" {
    for (0..2) |_| {
        try std.testing.expectError(error.OutOfMemory, runEntry("codex-auth switch fixture-account", &.{ "codex-auth", "switch", "fixture-account" }, std.testing.failing_allocator));
    }
    try std.testing.expectEqual(std.testing.io.userdata, codex_auth.core.runtime.io().userdata);
    try std.testing.expectEqual(std.testing.io.vtable, codex_auth.core.runtime.io().vtable);
}

test "runtime environment reads the supplied map and isolates child overrides" {
    const runtime = codex_auth.core.runtime;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CODEX_AUTH_RUNTIME_TEST", "parent");
    try env_map.put("CODEX_AUTH_RUNTIME_EMPTY", "");
    try env_map.put("NO_COLOR", "1");
    runtime.initRuntime(.{
        .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty },
        .arena = &arena,
        .gpa = allocator,
        .io = std.testing.io,
        .environ_map = &env_map,
        .preopens = .empty,
    });
    defer runtime.deinitRuntime();
    const value = try runtime.getEnvVarOwned(allocator, "CODEX_AUTH_RUNTIME_TEST");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("parent", value);
    try std.testing.expectError(error.EnvironmentVariableNotFound, runtime.getEnvVarOwned(allocator, "CODEX_AUTH_RUNTIME_MISSING"));
    try std.testing.expect(runtime.envHasValue("NO_COLOR"));
    try std.testing.expect(!codex_auth.terminal.color.fileColorEnabled(std.Io.File.stdout()));
    try std.testing.expect(!runtime.envHasValue("CODEX_AUTH_RUNTIME_EMPTY"));
    try std.testing.expect(!runtime.envHasValue("CODEX_AUTH_RUNTIME_MISSING"));
    var child_env = try runtime.getEnvMap(allocator);
    defer child_env.deinit();
    try child_env.put("CODEX_AUTH_RUNTIME_TEST", "child");
    try std.testing.expectEqualStrings("parent", env_map.get("CODEX_AUTH_RUNTIME_TEST").?);
    try std.testing.expectEqualStrings("parent", value);
    try std.testing.expectEqualStrings("child", child_env.get("CODEX_AUTH_RUNTIME_TEST").?);
    if (builtin.os.tag == .windows) {
        const lower = try runtime.getEnvVarOwned(allocator, "codex_auth_runtime_test");
        defer allocator.free(lower);
        try std.testing.expectEqualStrings("parent", lower);
    }
}
