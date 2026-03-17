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

    try cli.writeHelp(&aw.writer, false);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "login [--skip]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "add [--no-login]") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "`add` is accepted as a deprecated alias for `login`.") != null);
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

test "Scenario: Given switch with positional selector when parsing then non-interactive target is preserved" {
    const gpa = std.testing.allocator;
    const args = [_][:0]const u8{ "codex-auth", "switch", "user@example.com#pro" };
    var cmd = try cli.parseArgs(gpa, &args);
    defer cli.freeCommand(gpa, &cmd);

    switch (cmd) {
        .switch_account => |opts| {
            try std.testing.expect(opts.email != null);
            try std.testing.expect(std.mem.eql(u8, opts.email.?, "user@example.com#pro"));
        },
        else => return error.TestExpectedEqual,
    }
}

test "Scenario: Given help when rendering then switch selector terminology is shown" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try cli.writeHelp(&aw.writer, false);

    const help = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, help, "switch [<selector>]") != null);
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
