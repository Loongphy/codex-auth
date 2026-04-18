const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;
    const compat_fs = b.createModule(.{
        .root_source_file = b.path("src/compat_fs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compat_process = b.createModule(.{
        .root_source_file = b.path("src/compat_process.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compat_time = b.createModule(.{
        .root_source_file = b.path("src/compat_time.zig"),
        .target = target,
        .optimize = optimize,
    });
    compat_time.addImport("compat_fs", compat_fs);
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_module.addImport("compat_fs", compat_fs);
    main_module.addImport("compat_process", compat_process);
    main_module.addImport("compat_time", compat_time);
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
        auto_module.addImport("compat_fs", compat_fs);
        auto_module.addImport("compat_process", compat_process);
        auto_module.addImport("compat_time", compat_time);
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
    test_module.addImport("compat_fs", compat_fs);
    test_module.addImport("compat_process", compat_process);
    test_module.addImport("compat_time", compat_time);
    const tests = b.addTest(.{
        .name = "codex-auth-test",
        .root_module = test_module,
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
