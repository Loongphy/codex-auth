const std = @import("std");
const cli = @import("../cli.zig");
const registry = @import("../registry.zig");

fn isHelp(cmd: cli.Command) bool {
    return switch (cmd) {
        .help => true,
        else => false,
    };
}

test "Scenario: Given login with skip when parsing then embedded login is disabled" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "login", "--skip" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .login => |opts| {
            try std.testing.expect(!opts.launch_codex_login);
            try std.testing.expect(opts.invocation == .login);
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given add alias with skip when parsing then legacy invocation is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "add", "--skip" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .login => |opts| {
            try std.testing.expect(!opts.launch_codex_login);
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
    auto_cfg.enabled = true;
    auto_cfg.threshold_5h_percent = 12;
    auto_cfg.threshold_weekly_percent = 8;

    try cli.writeHelp(&aw.writer, false, &auto_cfg);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "Auto Switch: ON (5h<12%, weekly<8%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "login [--skip]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "add [--no-login]") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "backup") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto ...") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto --5h <percent> [--weekly <percent>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "migrate") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "import --purge [<path>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "`add` is accepted as a deprecated alias for `login`.") != null);
}

test "Scenario: Given auto status when parsing then auto command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "status" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .auto_switch => |opts| switch (opts) {
            .action => |action| try std.testing.expect(action == .status),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given auto 5h threshold when parsing then threshold configuration is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--5h", "12" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .auto_switch => |opts| switch (opts) {
            .configure => |cfg| {
                try std.testing.expect(cfg.threshold_5h_percent != null);
                try std.testing.expect(cfg.threshold_5h_percent.? == 12);
                try std.testing.expect(cfg.threshold_weekly_percent == null);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given auto thresholds together when parsing then both window thresholds are preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--5h", "12", "--weekly", "8" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .auto_switch => |opts| switch (opts) {
            .configure => |cfg| {
                try std.testing.expect(cfg.threshold_5h_percent != null);
                try std.testing.expect(cfg.threshold_5h_percent.? == 12);
                try std.testing.expect(cfg.threshold_weekly_percent != null);
                try std.testing.expect(cfg.threshold_weekly_percent.? == 8);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given auto action mixed with threshold flags when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "enable", "--5h", "12" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given auto threshold percent out of range when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--weekly", "0" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given auto repeated threshold flag when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--5h", "12", "--5h", "15" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given auto threshold without value when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--weekly" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given auto threshold command without flags when parsing then help command is returned" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    try std.testing.expect(isHelp(cmd));
}

test "Scenario: Given auto threshold with weekly only when parsing then single-window config is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "--weekly", "9" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .auto_switch => |opts| switch (opts) {
            .configure => |cfg| {
                try std.testing.expect(cfg.threshold_5h_percent == null);
                try std.testing.expect(cfg.threshold_weekly_percent != null);
                try std.testing.expect(cfg.threshold_weekly_percent.? == 9);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
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
        .daemon => |opts| try std.testing.expect(opts.watch),
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
