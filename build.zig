const std = @import("std");

fn linkWindowsTaskSchedulerLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("oleaut32", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (is_windows) {
        linkWindowsTaskSchedulerLibraries(main_module);
    }
    const exe = b.addExecutable(.{
        .name = "codex-auth",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    if (is_windows) {
        const auto_module = b.createModule(.{
            .root_source_file = b.path("src/windows_auto_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        linkWindowsTaskSchedulerLibraries(auto_module);
        const auto_exe = b.addExecutable(.{
            .name = "codex-auth-auto",
            .root_module = auto_module,
        });
        auto_exe.subsystem = .Windows;
        b.installArtifact(auto_exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run codex-auth");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (is_windows) {
        linkWindowsTaskSchedulerLibraries(test_module);
    }
    const tests = b.addTest(.{
        .name = "codex-auth-test",
        .root_module = test_module,
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
