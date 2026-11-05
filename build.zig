const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests matching these substrings") orelse &.{};
    // Point e2e harnesses at a prebuilt CLI (e.g. a ReleaseSafe staging
    // prefix) instead of the debug zig-out install they build themselves.
    const cli_prefix = b.option([]const u8, "cli-prefix", "Reuse the CLI installed under this prefix for e2e tests");
    // Stripped binaries start faster cold: non-loadable DWARF sections still
    // get pulled in by kernel readahead around demand-paged .text pages.
    const strip = b.option(bool, "strip", "Strip debug info") orelse (optimize != .debug);
    const c_time_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c_time.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_time_module = c_time_translate.createModule();

    const package_module = b.addModule("codex_auth", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .imports = &.{
            .{ .name = "c_time", .module = c_time_module },
        },
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .imports = &.{
            .{ .name = "codex_auth", .module = package_module },
        },
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
    run_cmd.addPassthruArgs();
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
        "tests/tui_conhost_test.zig",
        "tests/tui_display_test.zig",
        "tests/tui_pty_test.zig",
        "tests/tui_session_test.zig",
        "tests/tui_table_test.zig",
        "tests/workflows_core_test.zig",
        "tests/workflows_daemon_test.zig",
        "tests/workflows_live_test.zig",
    };

    const test_options = b.addOptions();
    test_options.addOptionPathUntracked("zig_exe", .zig_exe);
    test_options.addOptionPathUntracked("project_root", b.path("."));

    const test_step = b.step("test", "Run tests");
    // The windows conhost harness resolves zig-out/bin/codex-auth.exe, so
    // `zig build test` must also install the CLI binary.
    test_step.dependOn(b.getInstallStep());
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
        test_module.addOptions("test_options", test_options);
        const test_artifact = b.addTest(.{
            // Named after the file stem so cross-compiled artifacts (e.g.
            // the conhost harness run on a Windows host) stay identifiable.
            .name = std.Io.Dir.path.stem(test_file),
            .root_module = test_module,
            .filters = test_filters,
        });
        // Plain Run step instead of addRunArtifact: the default server-mode
        // test runner (--listen=-) can deadlock the build runner on Windows
        // (upstream Zig std.zig.Server race). Exit code decides pass/fail.
        const run_test = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{test_file}));
        run_test.addArtifactArg(test_artifact);
        run_test.setEnvironmentVariable(
            "CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT",
            b.root.joinString(b.allocator, &.{}) catch @panic("OOM"),
        );
        if (cli_prefix) |prefix| {
            run_test.setEnvironmentVariable("CODEX_AUTH_CLI_INTEGRATION_INSTALL_PREFIX", prefix);
        }
        if (std.mem.eql(u8, test_file, "tests/cli_integration_test.zig")) {
            run_test.addFileInput(exe.getEmittedBin());
            run_test.addFileInput(fake_curl_exe.getEmittedBin());
            run_test.addFileInput(fake_curl_fail_exe.getEmittedBin());
            run_test.addFileInput(fake_codex_exe.getEmittedBin());
            run_test.addFileInput(b.path("build.zig"));
            run_test.addFileInput(b.path("build.zig.zon"));
        }
        // Each run step — not just the umbrella test step — must wait for
        // the CLI install: sibling steps are unordered, so the harnesses
        // resolving zig-out/bin could otherwise race it or reuse a stale
        // binary from a previous build.
        run_test.step.dependOn(b.getInstallStep());
        test_step.dependOn(&run_test.step);
    }
}
