const std = @import("std");
const builtin = @import("builtin");
const registry = @import("registry.zig");
const io_util = @import("io_util.zig");
const timefmt = @import("timefmt.zig");
const version = @import("version.zig");
const c = @cImport({
    @cInclude("time.h");
});

const ansi = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const bold_red = "\x1b[1;31m";
    const green = "\x1b[32m";
    const bold_green = "\x1b[1;32m";
    const bold = "\x1b[1m";
};

fn colorEnabled() bool {
    return std.fs.File.stdout().isTty();
}

fn stderrColorEnabled() bool {
    return std.fs.File.stderr().isTty();
}

pub const OutputFormat = enum { table, json, csv, compact };

pub const ListOptions = struct {};
pub const LoginInvocation = enum { login, add_alias };
pub const LoginOptions = struct {
    launch_codex_login: bool,
    invocation: LoginInvocation,
};
pub const ImportOptions = struct { auth_path: []u8, alias: ?[]u8 };
pub const SwitchOptions = struct { email: ?[]u8 };
pub const RemoveOptions = struct {};
pub const AutoAction = enum { enable, disable, status };
pub const AutoOptions = struct { action: AutoAction };
pub const DaemonOptions = struct { watch: bool };

pub const Command = union(enum) {
    list: ListOptions,
    login: LoginOptions,
    import_auth: ImportOptions,
    switch_account: SwitchOptions,
    remove_account: RemoveOptions,
    auto_switch: AutoOptions,
    daemon: DaemonOptions,
    version: void,
    help: void,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !Command {
    if (args.len < 2) return Command{ .help = {} };
    const cmd = std.mem.sliceTo(args[1], 0);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        if (args.len > 2) return Command{ .help = {} };
        return Command{ .version = {} };
    }

    if (std.mem.eql(u8, cmd, "list")) {
        if (args.len > 2) return Command{ .help = {} };
        return Command{ .list = .{} };
    }

    if (std.mem.eql(u8, cmd, "login") or std.mem.eql(u8, cmd, "add")) {
        const invocation: LoginInvocation = if (std.mem.eql(u8, cmd, "add")) .add_alias else .login;
        var launch_codex_login = true;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--skip")) {
                launch_codex_login = false;
            } else {
                return Command{ .help = {} };
            }
        }
        return Command{ .login = .{
            .launch_codex_login = launch_codex_login,
            .invocation = invocation,
        } };
    }

    if (std.mem.eql(u8, cmd, "import")) {
        var auth_path: ?[]u8 = null;
        var alias: ?[]u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--alias") and i + 1 < args.len) {
                if (alias) |a| allocator.free(a);
                alias = try allocator.dupe(u8, std.mem.sliceTo(args[i + 1], 0));
                i += 1;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                if (auth_path) |p| allocator.free(p);
                if (alias) |a| allocator.free(a);
                return Command{ .help = {} };
            } else {
                if (auth_path != null) {
                    if (auth_path) |p| allocator.free(p);
                    if (alias) |a| allocator.free(a);
                    return Command{ .help = {} };
                }
                auth_path = try allocator.dupe(u8, arg);
            }
        }
        if (auth_path == null) return Command{ .help = {} };
        return Command{ .import_auth = .{ .auth_path = auth_path.?, .alias = alias } };
    }

    if (std.mem.eql(u8, cmd, "switch")) {
        var email: ?[]u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.startsWith(u8, arg, "-")) {
                if (email) |e| allocator.free(e);
                return Command{ .help = {} };
            }
            if (email != null) {
                if (email) |e| allocator.free(e);
                return Command{ .help = {} };
            }
            email = try allocator.dupe(u8, arg);
        }
        return Command{ .switch_account = .{ .email = email } };
    }

    if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len > 2) return Command{ .help = {} };
        return Command{ .remove_account = .{} };
    }

    if (std.mem.eql(u8, cmd, "auto")) {
        if (args.len != 3) return Command{ .help = {} };
        const action = std.mem.sliceTo(args[2], 0);
        if (std.mem.eql(u8, action, "enable")) return Command{ .auto_switch = .{ .action = .enable } };
        if (std.mem.eql(u8, action, "disable")) return Command{ .auto_switch = .{ .action = .disable } };
        if (std.mem.eql(u8, action, "status")) return Command{ .auto_switch = .{ .action = .status } };
        return Command{ .help = {} };
    }

    if (std.mem.eql(u8, cmd, "daemon")) {
        if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--watch")) {
            return Command{ .daemon = .{ .watch = true } };
        }
        return Command{ .help = {} };
    }

    return Command{ .help = {} };
}

pub fn freeCommand(allocator: std.mem.Allocator, cmd: *Command) void {
    switch (cmd.*) {
        .import_auth => |*opts| {
            allocator.free(opts.auth_path);
            if (opts.alias) |a| allocator.free(a);
        },
        .switch_account => |*opts| {
            if (opts.email) |e| allocator.free(e);
        },
        else => {},
    }
}

pub fn printHelp(auto_enabled: bool) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = colorEnabled();
    try writeHelp(out, use_color, auto_enabled);
    try out.flush();
}

pub fn writeHelp(out: *std.Io.Writer, use_color: bool, auto_enabled: bool) !void {
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("codex-auth");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll(" ");
    if (use_color) try out.writeAll(ansi.dim);
    try out.writeAll(version.app_version);
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Auto Switch:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.print(" {s}\n\n", .{if (auto_enabled) "ON" else "OFF"});

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");

    try writeHelpCommand(out, use_color, "--version, -V", "Show version");
    try writeHelpCommand(out, use_color, "list", "List available accounts");
    try writeHelpCommand(out, use_color, "login [--skip]", "Login and add the current account");
    try writeHelpCommand(out, use_color, "import <path> [--alias <alias>]", "Import one auth file or a directory");
    try writeHelpCommand(out, use_color, "switch [<email-prefix-or-part>]", "Switch the active account");
    try writeHelpCommand(out, use_color, "remove", "Remove one or more accounts");
    try writeHelpCommand(out, use_color, "auto enable|disable|status", "Manage background auto-switching");

    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");
    try out.writeAll("  `add` is accepted as a deprecated alias for `login`.\n");
    try out.writeAll("  Use `--skip` to read the current auth without running `codex login`.\n");
}

fn writeHelpCommand(out: *std.Io.Writer, use_color: bool, name: []const u8, description: []const u8) !void {
    if (use_color) try out.writeAll(ansi.bold_green);
    try out.print("  {s}", .{name});
    if (use_color) try out.writeAll(ansi.reset);

    const target_col: usize = 16;
    const visible_len = 2 + name.len;
    const spaces = if (visible_len >= target_col) 2 else target_col - visible_len;
    var i: usize = 0;
    while (i < spaces) : (i += 1) {
        try out.writeAll(" ");
    }

    try out.writeAll(description);
    try out.writeAll("\n");
}

pub fn printVersion() !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try out.print("codex-auth {s}\n", .{version.app_version});
    try out.flush();
}

pub fn warnDeprecatedLoginAlias(opts: LoginOptions) void {
    if (opts.invocation != .add_alias) return;
    const replacement = if (opts.launch_codex_login) "codex-auth login" else "codex-auth login --skip";
    writeDeprecatedLoginAliasWarning(replacement, stderrColorEnabled()) catch {};
}

fn writeDeprecatedLoginAliasWarning(replacement: []const u8, use_color: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    try writeDeprecatedLoginAliasWarningTo(out, replacement, use_color);
    try out.flush();
}

pub fn writeDeprecatedLoginAliasWarningTo(out: *std.Io.Writer, replacement: []const u8, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold_red);
    try out.writeAll("warning:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll(" ");
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("`add`");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll(" is deprecated; use ");
    if (use_color) try out.writeAll(ansi.bold_green);
    try out.print("`{s}`", .{replacement});
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n");
}

pub fn runCodexLogin(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var child = std.process.Child.init(&[_][]const u8{ "codex", "login" }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = try child.spawnAndWait();
}

pub fn selectAccount(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    return if (comptime builtin.os.tag == .windows)
        selectWithNumbers(reg)
    else
        selectInteractive(allocator, reg) catch selectWithNumbers(reg);
}

pub fn selectAccountFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    if (indices.len == 0) return null;
    if (indices.len == 1) return reg.accounts.items[indices[0]].email;
    return if (comptime builtin.os.tag == .windows)
        selectWithNumbersFromIndices(allocator, reg, indices)
    else
        selectInteractiveFromIndices(allocator, reg, indices) catch selectWithNumbersFromIndices(allocator, reg, indices);
}

pub fn selectAccountsToRemove(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    if (comptime builtin.os.tag == .windows) {
        return selectRemoveWithNumbers(allocator, reg);
    }
    return selectRemoveInteractive(allocator, reg) catch selectRemoveWithNumbers(allocator, reg);
}

fn activeAccountIndex(reg: *registry.Registry) ?usize {
    if (reg.active_email) |key| {
        for (reg.accounts.items, 0..) |rec, i| {
            if (std.mem.eql(u8, key, rec.email)) return i;
        }
    }
    return null;
}

fn selectWithNumbers(reg: *registry.Registry) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRows(std.heap.page_allocator, reg);
    defer rows.deinit(std.heap.page_allocator);
    const use_color = colorEnabled();
    const active_idx = activeAccountIndex(reg);
    const idx_width = @max(@as(usize, 2), indexWidth(reg.accounts.items.len));
    const widths = rows.widths;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_idx, use_color);
    try out.writeAll("Select account number: ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return reg.accounts.items[i].email;
        return null;
    }
    const idx = std.fmt.parseInt(usize, line, 10) catch return null;
    if (idx == 0 or idx > reg.accounts.items.len) return null;
    return reg.accounts.items[idx - 1].email;
}

fn selectWithNumbersFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (indices.len == 0) return null;

    var rows = try buildSwitchRowsFromIndices(allocator, reg, indices);
    defer rows.deinit(allocator);
    const use_color = colorEnabled();
    const active_idx = activeCandidateIndex(reg, indices);
    const idx_width = @max(@as(usize, 2), indexWidth(indices.len));
    const widths = rows.widths;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_idx, use_color);
    try out.writeAll("Select account number: ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return reg.accounts.items[indices[i]].email;
        return null;
    }
    const idx = std.fmt.parseInt(usize, line, 10) catch return null;
    if (idx == 0 or idx > indices.len) return null;
    return reg.accounts.items[indices[idx - 1]].email;
}

fn selectInteractiveFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    if (indices.len == 0) return null;
    var rows = try buildSwitchRowsFromIndices(allocator, reg, indices);
    defer rows.deinit(allocator);

    var tty = try std.fs.cwd().openFile("/dev/tty", .{});
    defer tty.close();

    const term = try std.posix.tcgetattr(tty.handle);
    var raw = term;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, term) catch {};

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const active_idx = activeCandidateIndex(reg, indices);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(indices.len));
    const widths = rows.widths;

    while (true) {
        try out.writeAll("\x1b[2J\x1b[H");
        try out.writeAll("Select account to activate:\n\n");
        try renderSwitchList(out, reg, rows.items, idx_width, widths, idx, use_color);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll("Keys: ↑/↓ or j/k, Enter select, 1-9 type, Backspace edit, Esc exit\n");
        if (use_color) try out.writeAll(ansi.reset);
        try out.flush();

        var b: [8]u8 = undefined;
        const n = try tty.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                if (i + 2 < n and b[i + 1] == '[') {
                    const code = b[i + 2];
                    if (code == 'A' and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    } else if (code == 'B' and idx + 1 < indices.len) {
                        idx += 1;
                        number_len = 0;
                    }
                    i += 2;
                    continue;
                }
                return null;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (number_len > 0) {
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= indices.len) {
                        return reg.accounts.items[indices[parsed - 1]].email;
                    }
                }
                return reg.accounts.items[indices[idx]].email;
            }

            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= indices.len) {
                            idx = parsed - 1;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= indices.len) {
                        idx = parsed - 1;
                    }
                }
                continue;
            }
        }
    }
}

fn selectRemoveWithNumbers(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRows(std.heap.page_allocator, reg);
    defer rows.deinit(std.heap.page_allocator);
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(reg.accounts.items.len));
    const widths = rows.widths;

    var checked = try allocator.alloc(bool, reg.accounts.items.len);
    defer allocator.free(checked);
    @memset(checked, false);

    try out.writeAll("Select accounts to delete:\n\n");
    try renderRemoveList(out, reg, rows.items, idx_width, widths, null, checked, use_color);
    try out.writeAll("Enter account numbers (comma/space separated, empty to cancel): ");
    try out.flush();

    var buf: [256]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) return null;

    var current: usize = 0;
    var in_number = false;
    for (line) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + @as(usize, ch - '0');
            in_number = true;
            continue;
        }
        if (in_number) {
            if (current >= 1 and current <= reg.accounts.items.len) {
                checked[current - 1] = true;
            }
            current = 0;
            in_number = false;
        }
    }
    if (in_number and current >= 1 and current <= reg.accounts.items.len) {
        checked[current - 1] = true;
    }

    var count: usize = 0;
    for (checked) |flag| {
        if (flag) count += 1;
    }
    if (count == 0) return null;
    var selected = try allocator.alloc(usize, count);
    var idx: usize = 0;
    for (checked, 0..) |flag, i| {
        if (!flag) continue;
        selected[idx] = i;
        idx += 1;
    }
    return selected;
}

fn selectInteractive(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRows(allocator, reg);
    defer rows.deinit(allocator);

    var tty = try std.fs.cwd().openFile("/dev/tty", .{});
    defer tty.close();

    const term = try std.posix.tcgetattr(tty.handle);
    var raw = term;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, term) catch {};

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const active_idx = activeAccountIndex(reg);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(reg.accounts.items.len));
    const widths = rows.widths;

    while (true) {
        try out.writeAll("\x1b[2J\x1b[H");
        try out.writeAll("Select account to activate:\n\n");
        try renderSwitchList(out, reg, rows.items, idx_width, widths, idx, use_color);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll("Keys: ↑/↓ or j/k, Enter select, 1-9 type, Backspace edit, Esc exit\n");
        if (use_color) try out.writeAll(ansi.reset);
        try out.flush();

        var b: [8]u8 = undefined;
        const n = try tty.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                if (i + 2 < n and b[i + 1] == '[') {
                    const code = b[i + 2];
                    if (code == 'A' and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    } else if (code == 'B' and idx + 1 < reg.accounts.items.len) {
                        idx += 1;
                        number_len = 0;
                    }
                    i += 2;
                    continue;
                }
                return null;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                if (number_len > 0) {
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= reg.accounts.items.len) {
                        return reg.accounts.items[parsed - 1].email;
                    }
                }
                return reg.accounts.items[idx].email;
            }
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < reg.accounts.items.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= reg.accounts.items.len) {
                            idx = parsed - 1;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= reg.accounts.items.len) {
                        idx = parsed - 1;
                    }
                }
                continue;
            }
        }
    }
}

fn selectRemoveInteractive(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRows(allocator, reg);
    defer rows.deinit(allocator);

    var tty = try std.fs.cwd().openFile("/dev/tty", .{});
    defer tty.close();

    const term = try std.posix.tcgetattr(tty.handle);
    var raw = term;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    try std.posix.tcsetattr(tty.handle, .FLUSH, raw);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, term) catch {};

    var checked = try allocator.alloc(bool, reg.accounts.items.len);
    defer allocator.free(checked);
    @memset(checked, false);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    var idx: usize = 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(reg.accounts.items.len));
    const widths = rows.widths;

    while (true) {
        try out.writeAll("\x1b[2J\x1b[H");
        try out.writeAll("Select accounts to delete:\n\n");
        try renderRemoveList(out, reg, rows.items, idx_width, widths, idx, checked, use_color);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll("Keys: ↑/↓ or j/k move, Space toggle, Enter delete, 1-9 type, Backspace edit, Esc exit\n");
        if (use_color) try out.writeAll(ansi.reset);
        try out.flush();

        var b: [8]u8 = undefined;
        const n = try tty.read(&b);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (b[i] == 0x1b) {
                if (i + 2 < n and b[i + 1] == '[') {
                    const code = b[i + 2];
                    if (code == 'A' and idx > 0) {
                        idx -= 1;
                        number_len = 0;
                    } else if (code == 'B' and idx + 1 < reg.accounts.items.len) {
                        idx += 1;
                        number_len = 0;
                    }
                    i += 2;
                    continue;
                }
                return null;
            }

            if (b[i] == '\r' or b[i] == '\n') {
                var count: usize = 0;
                for (checked) |flag| {
                    if (flag) count += 1;
                }
                if (count == 0) return null;
                var selected = try allocator.alloc(usize, count);
                var out_idx: usize = 0;
                for (checked, 0..) |flag, sel_idx| {
                    if (!flag) continue;
                    selected[out_idx] = sel_idx;
                    out_idx += 1;
                }
                return selected;
            }
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < reg.accounts.items.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == ' ') {
                checked[idx] = !checked[idx];
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= reg.accounts.items.len) {
                            idx = parsed - 1;
                        }
                    }
                }
                continue;
            }
            if (b[i] >= '0' and b[i] <= '9') {
                if (number_len < number_buf.len) {
                    number_buf[number_len] = b[i];
                    number_len += 1;
                    const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                    if (parsed >= 1 and parsed <= reg.accounts.items.len) {
                        idx = parsed - 1;
                    }
                }
                continue;
            }
        }
    }
}

fn renderSwitchList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
) !void {
    _ = reg;
    const prefix = 2 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "EMAIL", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    for (rows, 0..) |row, i| {
        const is_selected = selected != null and selected.? == i;
        const is_active = row.is_active;
        if (use_color) {
            if (is_selected) {
                try out.writeAll(ansi.bold_green);
            } else if (is_active) {
                try out.writeAll(ansi.green);
            } else {
                try out.writeAll(ansi.dim);
            }
        }
        try out.writeAll(if (is_selected) "> " else "  ");
        try writeIndexPadded(out, i + 1, idx_width);
        try out.writeAll(" ");
        try writeTruncatedPadded(out, row.email, widths.email);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        if (is_active) {
            try out.writeAll("  [ACTIVE]");
        }
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
}

fn renderRemoveList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
) !void {
    _ = reg;
    const checkbox_width: usize = 3;
    const prefix = 2 + checkbox_width + 1 + idx_width + 1;
    var pad: usize = 0;
    while (pad < prefix) : (pad += 1) {
        try out.writeAll(" ");
    }
    try writePadded(out, "EMAIL", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    for (rows, 0..) |row, i| {
        const is_cursor = cursor != null and cursor.? == i;
        const is_checked = checked[i];
        const is_active = row.is_active;
        if (use_color) {
            if (is_cursor) {
                try out.writeAll(ansi.bold_green);
            } else if (is_checked or is_active) {
                try out.writeAll(ansi.green);
            } else {
                try out.writeAll(ansi.dim);
            }
        }
        try out.writeAll(if (is_cursor) "> " else "  ");
        try out.writeAll(if (is_checked) "[x]" else "[ ]");
        try out.writeAll(" ");
        try writeIndexPadded(out, i + 1, idx_width);
        try out.writeAll(" ");
        try writeTruncatedPadded(out, row.email, widths.email);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.plan, widths.plan);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_5h, widths.rate_5h);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.rate_week, widths.rate_week);
        try out.writeAll("  ");
        try writeTruncatedPadded(out, row.last, widths.last);
        if (is_active) {
            try out.writeAll("  [ACTIVE]");
        }
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.reset);
    }
}

fn writeIndexPadded(out: *std.Io.Writer, idx: usize, width: usize) !void {
    var buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
    if (idx_str.len < width) {
        var pad: usize = width - idx_str.len;
        while (pad > 0) : (pad -= 1) {
            try out.writeAll("0");
        }
    }
    try out.writeAll(idx_str);
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    var i: usize = 0;
    const pad = width - value.len;
    while (i < pad) : (i += 1) {
        try out.writeAll(" ");
    }
}

fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width == 1) {
        try out.writeAll(".");
        return;
    }
    try out.writeAll(value[0 .. width - 1]);
    try out.writeAll(".");
}

const SwitchWidths = struct {
    email: usize,
    plan: usize,
    rate_5h: usize,
    rate_week: usize,
    last: usize,
};

const SwitchRow = struct {
    email: []const u8,
    plan: []const u8,
    rate_5h: []u8,
    rate_week: []u8,
    last: []u8,
    is_active: bool,

    fn deinit(self: *SwitchRow, allocator: std.mem.Allocator) void {
        allocator.free(self.rate_5h);
        allocator.free(self.rate_week);
        allocator.free(self.last);
    }
};

const SwitchRows = struct {
    items: []SwitchRow,
    widths: SwitchWidths,

    fn deinit(self: *SwitchRows, allocator: std.mem.Allocator) void {
        for (self.items) |*row| row.deinit(allocator);
        allocator.free(self.items);
    }
};

fn buildSwitchRows(allocator: std.mem.Allocator, reg: *registry.Registry) !SwitchRows {
    const count = reg.accounts.items.len;
    var rows = try allocator.alloc(SwitchRow, count);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.time.timestamp();
    for (reg.accounts.items, 0..) |rec, i| {
        const email = rec.email;
        const plan = if (registry.resolvePlan(&rec)) |p| @tagName(p) else "-";
        const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
        const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
        const rate_5h_str = try formatRateLimitSwitchAlloc(allocator, rate_5h);
        const rate_week_str = try formatRateLimitSwitchAlloc(allocator, rate_week);
        const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
        rows[i] = .{
            .email = email,
            .plan = plan,
            .rate_5h = rate_5h_str,
            .rate_week = rate_week_str,
            .last = last,
            .is_active = if (reg.active_email) |k| std.mem.eql(u8, k, rec.email) else false,
        };
        widths.email = @max(widths.email, email.len);
        widths.plan = @max(widths.plan, plan.len);
        widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
        widths.rate_week = @max(widths.rate_week, rate_week_str.len);
        widths.last = @max(widths.last, last.len);
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{ .items = rows, .widths = widths };
}

fn buildSwitchRowsFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !SwitchRows {
    const count = indices.len;
    var rows = try allocator.alloc(SwitchRow, count);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.time.timestamp();
    for (indices, 0..) |source_idx, i| {
        const rec = reg.accounts.items[source_idx];
        const email = rec.email;
        const plan = if (registry.resolvePlan(&rec)) |p| @tagName(p) else "-";
        const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
        const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
        const rate_5h_str = try formatRateLimitSwitchAlloc(allocator, rate_5h);
        const rate_week_str = try formatRateLimitSwitchAlloc(allocator, rate_week);
        const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
        rows[i] = .{
            .email = email,
            .plan = plan,
            .rate_5h = rate_5h_str,
            .rate_week = rate_week_str,
            .last = last,
            .is_active = if (reg.active_email) |k| std.mem.eql(u8, k, rec.email) else false,
        };
        widths.email = @max(widths.email, email.len);
        widths.plan = @max(widths.plan, plan.len);
        widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
        widths.rate_week = @max(widths.rate_week, rate_week_str.len);
        widths.last = @max(widths.last, last.len);
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{ .items = rows, .widths = widths };
}

fn activeCandidateIndex(reg: *registry.Registry, indices: []const usize) ?usize {
    if (reg.active_email) |active| {
        for (indices, 0..) |source_idx, position| {
            if (std.mem.eql(u8, reg.accounts.items[source_idx].email, active)) return position;
        }
    }
    return null;
}

fn resolveRateWindow(usage: ?registry.RateLimitSnapshot, minutes: i64, fallback_primary: bool) ?registry.RateLimitWindow {
    if (usage == null) return null;
    if (usage.?.primary) |p| {
        if (p.window_minutes != null and p.window_minutes.? == minutes) return p;
    }
    if (usage.?.secondary) |s| {
        if (s.window_minutes != null and s.window_minutes.? == minutes) return s;
    }
    return if (fallback_primary) usage.?.primary else usage.?.secondary;
}

fn formatRateLimitSwitchAlloc(allocator: std.mem.Allocator, window: ?registry.RateLimitWindow) ![]u8 {
    if (window == null) return try std.fmt.allocPrint(allocator, "-", .{});
    if (window.?.resets_at == null) return try std.fmt.allocPrint(allocator, "-", .{});
    const now = std.time.timestamp();
    const reset_at = window.?.resets_at.?;
    if (now >= reset_at) {
        return try std.fmt.allocPrint(allocator, "100%", .{});
    }
    const remaining = remainingPercent(window.?.used_percent);
    var parts = try resetPartsAlloc(allocator, reset_at, now);
    defer parts.deinit(allocator);
    if (parts.same_day) {
        return std.fmt.allocPrint(allocator, "{d}% ({s})", .{ remaining, parts.time });
    }
    return std.fmt.allocPrint(allocator, "{d}% ({s} on {s})", .{ remaining, parts.time, parts.date });
}

const ResetParts = struct {
    time: []u8,
    date: []u8,
    same_day: bool,

    fn deinit(self: *ResetParts, allocator: std.mem.Allocator) void {
        allocator.free(self.time);
        allocator.free(self.date);
    }
};

fn localtimeCompat(ts: i64, out_tm: *c.struct_tm) bool {
    if (comptime builtin.os.tag == .windows) {
        // Bind directly to the exported CRT symbol on Windows.
        if (comptime @hasDecl(c, "_localtime64_s") and @hasDecl(c, "__time64_t")) {
            var t64 = std.math.cast(c.__time64_t, ts) orelse return false;
            return c._localtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    var t = std.math.cast(c.time_t, ts) orelse return false;
    if (comptime @hasDecl(c, "localtime_r")) {
        return c.localtime_r(&t, out_tm) != null;
    }

    if (comptime @hasDecl(c, "localtime")) {
        const tm_ptr = c.localtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }

    return false;
}

fn resetPartsAlloc(allocator: std.mem.Allocator, reset_at: i64, now: i64) !ResetParts {
    var tm: c.struct_tm = undefined;
    if (!localtimeCompat(reset_at, &tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }
    var now_tm: c.struct_tm = undefined;
    if (!localtimeCompat(now, &now_tm)) {
        return ResetParts{
            .time = try std.fmt.allocPrint(allocator, "-", .{}),
            .date = try std.fmt.allocPrint(allocator, "-", .{}),
            .same_day = true,
        };
    }

    const same_day = tm.tm_year == now_tm.tm_year and tm.tm_mon == now_tm.tm_mon and tm.tm_mday == now_tm.tm_mday;
    const hour = @as(u32, @intCast(tm.tm_hour));
    const min = @as(u32, @intCast(tm.tm_min));
    const day = @as(u32, @intCast(tm.tm_mday));
    const months = [_][]const u8{
        "Jan",
        "Feb",
        "Mar",
        "Apr",
        "May",
        "Jun",
        "Jul",
        "Aug",
        "Sep",
        "Oct",
        "Nov",
        "Dec",
    };
    const month_idx: usize = if (tm.tm_mon < 0) 0 else @min(@as(usize, @intCast(tm.tm_mon)), months.len - 1);
    return ResetParts{
        .time = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ hour, min }),
        .date = try std.fmt.allocPrint(allocator, "{d} {s}", .{ day, months[month_idx] }),
        .same_day = same_day,
    };
}

fn remainingPercent(used: f64) i64 {
    const remaining = 100.0 - used;
    if (remaining <= 0.0) return 0;
    if (remaining >= 100.0) return 100;
    return @as(i64, @intFromFloat(remaining));
}


fn indexWidth(count: usize) usize {
    var n = count;
    var width: usize = 1;
    while (n >= 10) : (n /= 10) {
        width += 1;
    }
    return width;
}
