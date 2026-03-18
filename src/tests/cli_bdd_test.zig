const std = @import("std");
const cli = @import("../cli.zig");
const registry = @import("../registry.zig");

fn isHelp(cmd: cli.Command) bool {
    return switch (cmd) {
        .help => true,
        else => false,
    };
}

test "Scenario: Given add alias when parsing then legacy invocation is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "add" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .login => |opts| {
            try std.testing.expect(opts.invocation == .add_alias);
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import path and alias when parsing then import options are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "/tmp/auth.json", "--alias", "personal" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .import_auth => |opts| {
            try std.testing.expect(opts.auth_path != null);
            try std.testing.expect(std.mem.eql(u8, opts.auth_path.?, "/tmp/auth.json"));
            try std.testing.expect(opts.alias != null);
            try std.testing.expect(std.mem.eql(u8, opts.alias.?, "personal"));
            try std.testing.expect(!opts.purge);
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import purge without path when parsing then purge mode is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--purge" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .import_auth => |opts| {
            try std.testing.expect(opts.auth_path == null);
            try std.testing.expect(opts.alias == null);
            try std.testing.expect(opts.purge);
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given import unknown short purge flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "-P", "/tmp/auth.json" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given import alias without path when parsing then help command is returned without leaks" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "import", "--alias", "personal" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given list with extra args when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "list", "unexpected" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given login with removed no-login flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--no-login" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given add alias with removed no-login flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "add", "--no-login" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given login with unknown flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--bad-flag" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given help when rendering then login and compatibility notes are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var auto_cfg = registry.defaultAutoSwitchConfig();
    var api_cfg = registry.defaultApiConfig();
    auto_cfg.enabled = true;
    auto_cfg.threshold_5h_percent = 12;
    auto_cfg.threshold_weekly_percent = 8;
    api_cfg.usage = true;

    try cli.writeHelp(&aw.writer, false, &auto_cfg, &api_cfg);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "Auto Switch: ON (5h<12%, weekly<8%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Usage API: ON (api-only)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Warning: Usage refresh is currently using the ChatGPT usage API") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "`codex-auth config api disable`") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "login") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "add [--no-login]") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "clean") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, help, "`add` is accepted as a deprecated alias for `login` and will be removed in the next release.") != null);
}

test "Scenario: Given local-only usage mode when rendering warning then nothing is printed" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeUsageApiRiskWarning(&aw.writer, false, false);

    try std.testing.expectEqualStrings("", aw.written());
}

test "Scenario: Given api-only usage mode when rendering warning then risk and fallback guidance are shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeUsageApiRiskWarning(&aw.writer, false, true);

    const warning = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, warning, "Warning: Usage refresh is currently using the ChatGPT usage API") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "may trigger OpenAI account restrictions or suspension") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "`codex-auth config api disable`") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "less accurate usage data") != null);
}

test "Scenario: Given status when parsing then status command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "status" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .status => {},
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto 5h threshold when parsing then threshold configuration is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
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
    }
}

test "Scenario: Given config auto thresholds together when parsing then both window thresholds are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12", "--weekly", "8" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
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
    }
}

test "Scenario: Given config auto enable when parsing then auto action is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "enable" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .config => |opts| switch (opts) {
            .auto_switch => |auto_opts| switch (auto_opts) {
                .action => |action| try std.testing.expect(action == .enable),
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
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .config => |opts| switch (opts) {
            .api_usage => |action| try std.testing.expect(action == .enable),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config api disable when parsing then api disable action is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "api", "disable" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .config => |opts| switch (opts) {
            .api_usage => |action| try std.testing.expect(action == .disable),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given config auto action mixed with threshold flags when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "enable", "--5h", "12" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config auto threshold percent out of range when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly", "0" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config auto repeated threshold flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--5h", "12", "--5h", "15" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config auto threshold without value when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config auto threshold command without flags when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config auto threshold with weekly only when parsing then single-window config is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "auto", "--weekly", "9" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
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
    }
}

test "Scenario: Given removed top-level auto command when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "enable" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given config api unknown action when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "config", "api", "status" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given status with extra args when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "status", "extra" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given migrate when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "migrate" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given clean when parsing then clean command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "clean" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .clean => {},
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given daemon watch when parsing then daemon command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "daemon", "--watch" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .daemon => |opts| try std.testing.expect(opts.mode == .watch),
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given daemon once when parsing then one-shot daemon command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "daemon", "--once" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .daemon => |opts| try std.testing.expect(opts.mode == .once),
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given deprecated add alias warning when rendering then colorized replacement is included" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeDeprecatedLoginAliasWarningTo(&aw.writer, "codex-auth login", true);

    const warning = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, warning, "\x1b[1;31mwarning:\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "\x1b[1m`add`\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "\x1b[1;32m`codex-auth login`\x1b[0m") != null);
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

test "Scenario: Given switch with positional query when parsing then non-interactive target is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "user@example.com" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .switch_account => |opts| {
            try std.testing.expect(opts.query != null);
            try std.testing.expect(std.mem.eql(u8, opts.query.?, "user@example.com"));
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given switch with duplicate target when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "a@example.com", "b@example.com" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given switch with unexpected flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "--email", "a@example.com" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}
