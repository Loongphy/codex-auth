const std = @import("std");

fn linkWindowsTaskSchedulerLibraries(module: *std.Build.Module) void {
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("oleaut32", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;
    const package_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (is_windows) {
        linkWindowsTaskSchedulerLibraries(package_module);
    }

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
            .root_source_file = b.path("src/auto_main.zig"),
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

    const test_files = [_][]const u8{
        "tests/api_account_test.zig",
        "tests/api_http_test.zig",
        "tests/api_usage_test.zig",
        "tests/auth_account_test.zig",
        "tests/auth_test.zig",
        "tests/auto_candidate_test.zig",
        "tests/auto_daemon_test.zig",
        "tests/cli_behavior_test.zig",
        "tests/cli_picker_test.zig",
        "tests/compat_fs_test.zig",
        "tests/cli_integration_test.zig",
        "tests/lib_compile_test.zig",
        "tests/registry_import_test.zig",
        "tests/registry_purge_import_test.zig",
        "tests/registry_test.zig",
        "tests/session_test.zig",
        "tests/terminal_color_test.zig",
        "tests/time_relative_test.zig",
        "tests/table_layout_test.zig",
        "tests/tui_display_test.zig",
        "tests/tui_session_test.zig",
        "tests/tui_table_test.zig",
        "tests/workflows_core_test.zig",
        "tests/workflows_live_test.zig",
    };

    const test_step = b.step("test", "Run tests");
    for (test_files) |test_file| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "codex_auth", .module = package_module },
            },
        });
        if (is_windows) {
            linkWindowsTaskSchedulerLibraries(test_module);
        }
        const test_artifact = b.addTest(.{
            .root_module = test_module,
        });
        const run_test = b.addRunArtifact(test_artifact);
        run_test.setEnvironmentVariable("CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT", b.pathFromRoot("."));
        test_step.dependOn(&run_test.step);
    }
}
