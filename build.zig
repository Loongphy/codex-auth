const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Stripped binaries start faster cold: non-loadable DWARF sections still
    // get pulled in by kernel readahead around demand-paged .text pages.
    const strip = b.option(bool, "strip", "Strip debug info") orelse (optimize != .Debug);
    const package_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    const exe = b.addExecutable(.{
        .name = "codex-auth",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const fake_curl_module = b.createModule(.{
        .root_source_file = b.path("tests/fake_curl.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fake_curl_exe = b.addExecutable(.{
        .name = "curl",
        .root_module = fake_curl_module,
    });
    const install_fake_curl = b.addInstallArtifact(fake_curl_exe, .{});
    const fake_curl_fail_module = b.createModule(.{
        .root_source_file = b.path("tests/fake_curl_fail.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fake_curl_fail_exe = b.addExecutable(.{
        .name = "curl-fail",
        .root_module = fake_curl_fail_module,
    });
    const install_fake_curl_fail = b.addInstallArtifact(fake_curl_fail_exe, .{});
    const fake_codex_module = b.createModule(.{
        .root_source_file = b.path("tests/fake_codex.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "app_runtime", .module = b.createModule(.{
                .root_source_file = b.path("src/core/runtime.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) },
        },
    });
    const fake_codex_exe = b.addExecutable(.{
        .name = "fake-codex",
        .root_module = fake_codex_module,
    });
    const install_fake_codex = b.addInstallArtifact(fake_codex_exe, .{});
    const test_helpers_step = b.step("test-helpers", "Install test helper binaries");
    test_helpers_step.dependOn(b.getInstallStep());
    test_helpers_step.dependOn(&install_fake_curl.step);
    test_helpers_step.dependOn(&install_fake_curl_fail.step);
    test_helpers_step.dependOn(&install_fake_codex.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run codex-auth");
    run_step.dependOn(&run_cmd.step);

    const test_files = [_][]const u8{
        "tests/api_account_test.zig",
        "tests/api_http_test.zig",
        "tests/api_me_test.zig",
        "tests/api_proxy_test.zig",
        "tests/api_reset_credits_test.zig",
        "tests/api_usage_test.zig",
        "tests/auth_test.zig",
        "tests/cli_behavior_test.zig",
        "tests/cli_picker_test.zig",
        "tests/compat_fs_test.zig",
        "tests/cli_integration_test.zig",
        "tests/lib_compile_test.zig",
        "tests/registry_import_test.zig",
        "tests/registry_test.zig",
        "tests/session_test.zig",
        "tests/time_relative_test.zig",
        "tests/time_timestamp_test.zig",
        "tests/table_layout_test.zig",
        "tests/tui_display_test.zig",
        "tests/tui_session_test.zig",
        "tests/tui_table_test.zig",
        "tests/workflows_core_test.zig",
        "tests/workflows_daemon_test.zig",
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
        const test_artifact = b.addTest(.{
            .root_module = test_module,
        });
        // Plain Run step instead of addRunArtifact: the default server-mode
        // test runner (--listen=-) can deadlock the build runner on Windows
        // (upstream Zig 0.16 std.zig.Server race). Exit code decides pass/fail.
        const run_test = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{test_file}));
        run_test.addArtifactArg(test_artifact);
        run_test.setEnvironmentVariable("CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT", b.pathFromRoot("."));
        test_step.dependOn(&run_test.step);
    }
}
