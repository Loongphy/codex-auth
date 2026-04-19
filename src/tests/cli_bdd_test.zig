const std = @import("std");
const cli = @import("../cli.zig");
const registry = @import("../registry.zig");

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn expectHelp(result: cli.ParseResult, topic: cli.HelpTopic) !void {
    switch (result) {
        .command => |cmd| switch (cmd) {
            .help => |actual| try std.testing.expectEqual(topic, actual),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectUsageError(result: cli.ParseResult, topic: cli.HelpTopic, contains: ?[]const u8) !void {
    switch (result) {
        .usage_error => |usage_err| {
            try std.testing.expectEqual(topic, usage_err.topic);
            if (contains) |needle| {
                try std.testing.expect(std.mem.indexOf(u8, usage_err.message, needle) != null);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectArgv(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

test "Scenario: Given import path and alias when parsing then import options are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "/tmp/auth.json", "--alias", "personal" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .import_auth => |opts| {
                try std.testing.expect(opts.auth_path != null);
                try std.testing.expect(std.mem.eql(u8, opts.auth_path.?, "/tmp/auth.json"));
                try std.testing.expect(opts.alias != null);
                try std.testing.expect(std.mem.eql(u8, opts.alias.?, "personal"));
                try std.testing.expect(!opts.purge);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import purge without path when parsing then purge mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--purge" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .import_auth => |opts| {
                try std.testing.expect(opts.auth_path == null);
                try std.testing.expect(opts.alias == null);
                try std.testing.expect(opts.purge);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import cpa without path when parsing then cpa mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--cpa" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .import_auth => |opts| {
                try std.testing.expect(opts.auth_path == null);
                try std.testing.expect(opts.alias == null);
                try std.testing.expect(!opts.purge);
                try std.testing.expectEqual(cli.ImportSource.cpa, opts.source);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import cpa with purge when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--cpa", "--purge" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .import_auth, "`--purge`");
}

test "Scenario: Given import unknown short purge flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "-P", "/tmp/auth.json" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .import_auth, "unknown flag");
}

test "Scenario: Given import alias without path when parsing then usage error is returned without leaks" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--alias", "personal" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .import_auth, "requires a path");
}

test "Scenario: Given list with extra args when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "unexpected" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .list, "unexpected argument");
}

test "Scenario: Given list with debug flag when parsing then debug mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "--debug" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .list => |opts| try std.testing.expect(opts.debug),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given list with skip-api flag when parsing then local-only display mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "--skip-api" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .list => |opts| try std.testing.expectEqual(cli.ApiMode.skip_api, opts.api_mode),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given list with api flag when parsing then forced api mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "--api" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .list => |opts| try std.testing.expectEqual(cli.ApiMode.force_api, opts.api_mode),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given login with removed no-login flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--no-login" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .login, "unknown flag");
}

test "Scenario: Given login with unknown flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--bad-flag" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .login, "unknown flag");
}

test "Scenario: Given login with device auth flag when parsing then device auth is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--device-auth" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .login => |opts| try std.testing.expect(opts.device_auth),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given login with duplicate device auth flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--device-auth", "--device-auth" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .login, "duplicate `--device-auth`");
}

test "Scenario: Given command help selector when parsing then command-specific help is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "help", "list" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectHelp(result, .list);
}

test "Scenario: Given help when rendering then login and command help notes are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var auto_cfg = registry.defaultAutoSwitchConfig();
    var api_cfg = registry.defaultApiConfig();
    auto_cfg.enabled = true;
    auto_cfg.threshold_5h_percent = 12;
    auto_cfg.threshold_weekly_percent = 8;
    api_cfg.usage = true;
    api_cfg.account = true;

    try cli.writeHelp(&aw.writer, false, &auto_cfg, &api_cfg);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "Auto Switch: ON (5h<12%, weekly<8%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage API: ON (api)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Account API: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--cpa [<path>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Run `codex-auth <command> --help` for command-specific usage details.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "`config api enable` may trigger OpenAI account restrictions or suspension in some environments.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "login") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "switch [--api|--skip-api] | switch <query>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "remove [<query>...] | remove --all") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Delete backup and stale files under accounts/") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "config") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto --5h <percent> [--weekly <percent>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "api enable") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "api disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto ...") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "migrate") == null);
}

test "Scenario: Given simple command help when rendering then examples are omitted" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeCommandHelp(&aw.writer, false, .list);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "codex-auth list") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "List available accounts.") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage:\n  codex-auth list [--debug] [--api|--skip-api]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:") == null);
}

test "Scenario: Given complex command help when rendering then examples are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeCommandHelp(&aw.writer, false, .import_auth);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "codex-auth import") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage:\n  codex-auth import <path> [--alias <alias>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:\n  codex-auth import /path/to/auth.json --alias personal\n") != null);
}

test "Scenario: Given scanned import report when rendering then stdout and stderr match the import format" {
    const gpa = std.testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(gpa);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(gpa);
    defer stderr_aw.deinit();

    var report = registry.ImportReport.init(.scanned);
    defer report.deinit(gpa);
    report.source_label = try gpa.dupe(u8, "./tokens/");
    try report.addEvent(gpa, "token_ryan.taylor.alpha@email.com", .imported, null);
    try report.addEvent(gpa, "token_jane.smith.alpha@email.com", .updated, null);
    try report.addEvent(gpa, "token_invalid", .skipped, "MalformedJson");

    try cli.writeImportReport(&stdout_aw.writer, &stderr_aw.writer, &report);

    try std.testing.expectEqualStrings(
        "Scanning ./tokens/...\n" ++
            "  ✓ imported  token_ryan.taylor.alpha@email.com\n" ++
            "  ✓ updated   token_jane.smith.alpha@email.com\n" ++
            "Import Summary: 1 imported, 1 updated, 1 skipped (total 3 files)\n",
        stdout_aw.written(),
    );
    try std.testing.expectEqualStrings(
        "  ✗ skipped   token_invalid: MalformedJson\n",
        stderr_aw.written(),
    );
}

test "Scenario: Given single-file skipped import report when rendering then summary stays concise" {
    const gpa = std.testing.allocator;
    var stdout_aw: std.Io.Writer.Allocating = .init(gpa);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(gpa);
    defer stderr_aw.deinit();

    var report = registry.ImportReport.init(.single_file);
    defer report.deinit(gpa);
    try report.addEvent(gpa, "token_bob.wilson.alpha@email.com", .skipped, "MissingEmail");

    try cli.writeImportReport(&stdout_aw.writer, &stderr_aw.writer, &report);

    try std.testing.expectEqualStrings(
        "Import Summary: 0 imported, 1 skipped\n",
        stdout_aw.written(),
    );
    try std.testing.expectEqualStrings(
        "  ✗ skipped   token_bob.wilson.alpha@email.com: MissingEmail\n",
        stderr_aw.written(),
    );
}

test "Scenario: Given status when parsing then status command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "status" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .status => {},
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto 5h threshold when parsing then threshold configuration is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .auto_switch => |auto_opts| switch (auto_opts) {
                    .configure => |cfg| {
                        try std.testing.expect(cfg.threshold_5h_percent != null);
                        try std.testing.expect(cfg.threshold_5h_percent.? == 12);
                        try std.testing.expect(cfg.threshold_weekly_percent == null);
                    },
                    else => return error.TestExpectedEqual,
                },
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto thresholds together when parsing then both window thresholds are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12", "--weekly", "8" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .auto_switch => |auto_opts| switch (auto_opts) {
                    .configure => |cfg| {
                        try std.testing.expect(cfg.threshold_5h_percent != null);
                        try std.testing.expect(cfg.threshold_5h_percent.? == 12);
                        try std.testing.expect(cfg.threshold_weekly_percent != null);
                        try std.testing.expect(cfg.threshold_weekly_percent.? == 8);
                    },
                    else => return error.TestExpectedEqual,
                },
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto enable when parsing then auto action is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "enable" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .auto_switch => |auto_opts| switch (auto_opts) {
                    .action => |action| try std.testing.expectEqual(cli.AutoAction.enable, action),
                    else => return error.TestExpectedEqual,
                },
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config api enable when parsing then api action is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "api", "enable" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .api => |action| try std.testing.expectEqual(cli.ApiAction.enable, action),
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config api disable when parsing then api disable action is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "api", "disable" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .api => |action| try std.testing.expectEqual(cli.ApiAction.disable, action),
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto action mixed with threshold flags when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "enable", "--5h", "12" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "cannot mix actions");
}

test "Scenario: Given config auto threshold percent out of range when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly", "0" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "`--weekly` must be an integer from 1 to 100.");
}

test "Scenario: Given config auto repeated threshold flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12", "--5h", "15" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "duplicate `--5h`");
}

test "Scenario: Given config auto threshold without value when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "missing value for `--weekly`");
}

test "Scenario: Given config auto threshold command without flags when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "requires an action or threshold flags");
}

test "Scenario: Given config auto threshold with weekly only when parsing then single-window config is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly", "9" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .config => |opts| switch (opts) {
                .auto_switch => |auto_opts| switch (auto_opts) {
                    .configure => |cfg| {
                        try std.testing.expect(cfg.threshold_5h_percent == null);
                        try std.testing.expect(cfg.threshold_weekly_percent != null);
                        try std.testing.expect(cfg.threshold_weekly_percent.? == 9);
                    },
                    else => return error.TestExpectedEqual,
                },
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given removed top-level auto command when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "enable" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .top_level, "unknown command `auto`");
}

test "Scenario: Given config api unknown action when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "api", "status" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .config, "unknown action `status`");
}

test "Scenario: Given status with extra args when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "status", "extra" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .status, "unexpected argument");
}

test "Scenario: Given migrate when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "migrate" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .top_level, "unknown command `migrate`");
}

test "Scenario: Given clean when parsing then clean command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "clean" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .clean => {},
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given daemon watch when parsing then daemon command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "daemon", "--watch" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .daemon => |opts| try std.testing.expectEqual(cli.DaemonMode.watch, opts.mode),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given daemon once when parsing then one-shot daemon command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "daemon", "--once" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .daemon => |opts| try std.testing.expectEqual(cli.DaemonMode.once, opts.mode),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given codex login access denied when rendering then plain English retry hint is included" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeCodexLoginLaunchFailureHintTo(&aw.writer, "AccessDenied", false);

    const hint = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, hint, "failed to launch the `codex login` process.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Try running `codex login` manually, then retry your command.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "AccessDenied") == null);
}

test "Scenario: Given codex login client missing when rendering then detection hint is included" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeCodexLoginLaunchFailureHintTo(&aw.writer, "FileNotFound", false);

    const hint = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, hint, "the `codex` executable was not found in your PATH.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Ensure the Codex CLI is installed and available in your environment.") != null);
}

test "Scenario: Given login help when rendering then device auth usage is included" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeCommandHelp(&aw.writer, false, .login);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "codex-auth login --device-auth") != null);
}

test "Scenario: Given login options when building codex argv then device auth is forwarded" {
    try expectArgv(cli.codexLoginArgs(.{}), &[_][]const u8{ "codex", "login" });
    try expectArgv(cli.codexLoginArgs(.{ .device_auth = true }), &[_][]const u8{ "codex", "login", "--device-auth" });
}

test "Scenario: Given switch with positional query when parsing then non-interactive target is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "user@example.com" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .switch_account => |opts| {
                try std.testing.expect(opts.query != null);
                try std.testing.expect(std.mem.eql(u8, opts.query.?, "user@example.com"));
                try std.testing.expectEqual(cli.ApiMode.default, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given switch query with skip-api flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "--skip-api", "02" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .switch_account, "does not support");
}

test "Scenario: Given switch query with api flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "--api", "02" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .switch_account, "does not support");
}

test "Scenario: Given switch with duplicate target when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "a@example.com", "b@example.com" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .switch_account, "unexpected extra query");
}

test "Scenario: Given switch with unexpected flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "--email", "a@example.com" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .switch_account, "unknown flag");
}

test "Scenario: Given remove with positional query when parsing then selector mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "user@example.com" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .remove_account => |opts| {
                try std.testing.expectEqual(@as(usize, 1), opts.selectors.len);
                try std.testing.expect(std.mem.eql(u8, opts.selectors[0], "user@example.com"));
                try std.testing.expect(!opts.all);
                try std.testing.expectEqual(cli.ApiMode.default, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given remove with all flag when parsing then all mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--all" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .remove_account => |opts| {
                try std.testing.expectEqual(@as(usize, 0), opts.selectors.len);
                try std.testing.expect(opts.all);
                try std.testing.expectEqual(cli.ApiMode.default, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given remove with multiple selectors when parsing then all selectors are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "01", "b@example.com", "03" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .remove_account => |opts| {
                try std.testing.expectEqual(@as(usize, 3), opts.selectors.len);
                try std.testing.expect(std.mem.eql(u8, opts.selectors[0], "01"));
                try std.testing.expect(std.mem.eql(u8, opts.selectors[1], "b@example.com"));
                try std.testing.expect(std.mem.eql(u8, opts.selectors[2], "03"));
                try std.testing.expect(!opts.all);
                try std.testing.expectEqual(cli.ApiMode.default, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given interactive remove with skip-api flag when parsing then skip-api mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--skip-api" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .remove_account => |opts| {
                try std.testing.expectEqual(@as(usize, 0), opts.selectors.len);
                try std.testing.expect(!opts.all);
                try std.testing.expectEqual(cli.ApiMode.skip_api, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given interactive remove with api flag when parsing then api mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--api" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    switch (result) {
        .command => |cmd| switch (cmd) {
            .remove_account => |opts| {
                try std.testing.expectEqual(@as(usize, 0), opts.selectors.len);
                try std.testing.expect(!opts.all);
                try std.testing.expectEqual(cli.ApiMode.force_api, opts.api_mode);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given remove query with skip-api flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--skip-api", "01" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .remove_account, "do not support");
}

test "Scenario: Given remove query with api flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--api", "work" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .remove_account, "do not support");
}

test "Scenario: Given remove all with api flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--api", "--all" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .remove_account, "do not support");
}

test "Scenario: Given remove with unexpected flag when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--email" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .remove_account, "unknown flag");
}

test "Scenario: Given remove with all and query when parsing then usage error is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "remove", "--all", "a@example.com" };
    var result = try cli.parseArgs(gpa, &args);
    defer cli.freeParseResult(gpa, &result);

    try expectUsageError(result, .remove_account, "cannot combine `--all`");
}

test "Scenario: Given multiple removed accounts when rendering summary then emails are joined on one line" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const emails = [_][]const u8{ "alpha@example.com", "beta@example.com" };

    try cli.writeRemoveSummaryTo(&aw.writer, &emails);

    try std.testing.expectEqualStrings(
        "Removed 2 account(s): alpha@example.com, beta@example.com\n",
        aw.written(),
    );
}

test "Scenario: Given multiple matched accounts when rendering confirmation then the prompt lists each email" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const emails = [_][]const u8{ "alpha@example.com", "beta@example.com" };

    try cli.writeRemoveConfirmationTo(&aw.writer, &emails);

    try std.testing.expectEqualStrings(
        "Matched multiple accounts:\n" ++
            "- alpha@example.com\n" ++
            "- beta@example.com\n" ++
            "Confirm delete? [y/N]: ",
        aw.written(),
    );
}

test "Scenario: Given singleton aliases from different emails when building remove labels then each label keeps email context" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-4QmYj7PkN2sLx8AcVbR3TwHd::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "alpha@example.com", "work", .team);
    try appendAccount(gpa, &reg, "user-8LnCq5VzR1mHx9SfKpT4JdWe::518a44d9-ba75-4bad-87e5-ae9377042960", "beta@example.com", "work", .team);

    const indices = [_]usize{ 0, 1 };
    var labels = try cli.buildRemoveLabels(gpa, &reg, &indices);
    defer {
        for (labels.items) |label| gpa.free(@constCast(label));
        labels.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 2), labels.items.len);
    try std.testing.expectEqualStrings("alpha@example.com / work", labels.items[0]);
    try std.testing.expectEqualStrings("beta@example.com / work", labels.items[1]);
}

test "Scenario: Given singleton account names from different emails when building remove labels then each label keeps email context" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-4QmYj7PkN2sLx8AcVbR3TwHd::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "alpha@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Workspace");
    try appendAccount(gpa, &reg, "user-8LnCq5VzR1mHx9SfKpT4JdWe::518a44d9-ba75-4bad-87e5-ae9377042960", "beta@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Workspace");

    const indices = [_]usize{ 0, 1 };
    var labels = try cli.buildRemoveLabels(gpa, &reg, &indices);
    defer {
        for (labels.items) |label| gpa.free(@constCast(label));
        labels.deinit(gpa);
    }

    try std.testing.expectEqual(@as(usize, 2), labels.items.len);
    try std.testing.expectEqualStrings("alpha@example.com / Workspace", labels.items[0]);
    try std.testing.expectEqualStrings("beta@example.com / Workspace", labels.items[1]);
}

test "Scenario: Given selector environment when deciding remove UI then non-tty or windows use the numbered selector" {
    try std.testing.expect(cli.shouldUseNumberedRemoveSelector(false, false));
    try std.testing.expect(!cli.shouldUseNumberedRemoveSelector(false, true));
    try std.testing.expect(cli.shouldUseNumberedRemoveSelector(true, true));
}
