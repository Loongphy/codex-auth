const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The upstream root currently pulls in components that still use Zig 0.15
    // APIs. Expose the primitives codex-auth needs through a narrow 0.16 root.
    _ = b.addModule("zigzag", .{
        .root_source_file = b.path("src/codex_auth_root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
