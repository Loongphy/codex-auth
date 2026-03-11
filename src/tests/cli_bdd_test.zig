const std = @import("std");
const cli = @import("../cli.zig");

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
            try std.testing.expect(std.mem.eql(u8, opts.auth_path, "/tmp/auth.json"));
            try std.testing.expect(opts.alias != null);
            try std.testing.expect(std.mem.eql(u8, opts.alias.?, "personal"));
        },
        else => return error.TestExpectedEqual,
    }
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

    try cli.writeHelp(&aw.writer, false, true);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "Auto Switch: ON") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "login [--skip]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "add [--no-login]") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "auto enable|disable|status") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "migrate") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "`add` is accepted as a deprecated alias for `login`.") != null);
}

test "Scenario: Given auto status when parsing then auto command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "auto", "status" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .auto_switch => |opts| try std.testing.expect(opts.action == .status),
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given migrate when parsing then migrate command is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "migrate" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .migrate => {},
        else => return error.TestExpectedEqual,
    }
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
