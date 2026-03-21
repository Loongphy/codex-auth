const std = @import("std");
const builtin = @import("builtin");
const display_rows = @import("display_rows.zig");
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
    const yellow = "\x1b[33m";
    const bold_yellow = "\x1b[1;33m";
    const green = "\x1b[32m";
    const bold_green = "\x1b[1;32m";
    const cyan = "\x1b[36m";
    const bold_cyan = "\x1b[1;36m";
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
pub const LoginOptions = struct { invocation: LoginInvocation };
pub const ImportSource = enum { standard, cpa };
pub const ImportOptions = struct {
    auth_path: ?[]u8,
    alias: ?[]u8,
    purge: bool,
    source: ImportSource,
};
pub const SwitchOptions = struct { query: ?[]u8 };
pub const RemoveOptions = struct {
    query: ?[]u8,
    all: bool,
};
pub const CleanOptions = struct {};
pub const AutoAction = enum { enable, disable };
pub const AutoThresholdOptions = struct {
    threshold_5h_percent: ?u8,
    threshold_weekly_percent: ?u8,
};
pub const AutoOptions = union(enum) {
    action: AutoAction,
    configure: AutoThresholdOptions,
};
pub const ApiUsageAction = enum { enable, disable };
pub const ConfigOptions = union(enum) {
    auto_switch: AutoOptions,
    api_usage: ApiUsageAction,
};
pub const DaemonMode = enum { watch, once };
pub const DaemonOptions = struct { mode: DaemonMode };

pub const Command = union(enum) {
    list: ListOptions,
    login: LoginOptions,
    import_auth: ImportOptions,
    switch_account: SwitchOptions,
    remove_account: RemoveOptions,
    clean: CleanOptions,
    config: ConfigOptions,
    status: void,
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
        if (args.len > 2) return Command{ .help = {} };
        const invocation: LoginInvocation = if (std.mem.eql(u8, cmd, "add")) .add_alias else .login;
        return Command{ .login = .{ .invocation = invocation } };
    }

    if (std.mem.eql(u8, cmd, "import")) {
        var auth_path: ?[]u8 = null;
        var alias: ?[]u8 = null;
        var purge = false;
        var source: ImportSource = .standard;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--alias") and i + 1 < args.len) {
                if (alias) |a| allocator.free(a);
                alias = try allocator.dupe(u8, std.mem.sliceTo(args[i + 1], 0));
                i += 1;
            } else if (std.mem.eql(u8, arg, "--purge")) {
                purge = true;
            } else if (std.mem.eql(u8, arg, "--cpa")) {
                if (source == .cpa) {
                    if (auth_path) |p| allocator.free(p);
                    if (alias) |a| allocator.free(a);
                    return Command{ .help = {} };
                }
                source = .cpa;
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
        if (purge and source == .cpa) {
            if (auth_path) |p| allocator.free(p);
            if (alias) |a| allocator.free(a);
            return Command{ .help = {} };
        }
        if (auth_path == null and !purge and source == .standard) {
            if (alias) |a| allocator.free(a);
            return Command{ .help = {} };
        }
        return Command{ .import_auth = .{
            .auth_path = auth_path,
            .alias = alias,
            .purge = purge,
            .source = source,
        } };
    }

    if (std.mem.eql(u8, cmd, "switch")) {
        var query: ?[]u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.startsWith(u8, arg, "-")) {
                if (query) |e| allocator.free(e);
                return Command{ .help = {} };
            }
            if (query != null) {
                if (query) |e| allocator.free(e);
                return Command{ .help = {} };
            }
            query = try allocator.dupe(u8, arg);
        }
        return Command{ .switch_account = .{ .query = query } };
    }

    if (std.mem.eql(u8, cmd, "remove")) {
        var query: ?[]u8 = null;
        var all = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);
            if (std.mem.eql(u8, arg, "--all")) {
                if (all or query != null) {
                    if (query) |q| allocator.free(q);
                    return Command{ .help = {} };
                }
                all = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) {
                if (query) |q| allocator.free(q);
                return Command{ .help = {} };
            }
            if (query != null or all) {
                if (query) |q| allocator.free(q);
                return Command{ .help = {} };
            }
            query = try allocator.dupe(u8, arg);
        }
        return Command{ .remove_account = .{ .query = query, .all = all } };
    }

    if (std.mem.eql(u8, cmd, "clean")) {
        if (args.len > 2) return Command{ .help = {} };
        return Command{ .clean = .{} };
    }

    if (std.mem.eql(u8, cmd, "status")) {
        if (args.len > 2) return Command{ .help = {} };
        return Command{ .status = {} };
    }

    if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) return Command{ .help = {} };
        const scope = std.mem.sliceTo(args[2], 0);

        if (std.mem.eql(u8, scope, "auto")) {
            if (args.len == 4) {
                const action = std.mem.sliceTo(args[3], 0);
                if (std.mem.eql(u8, action, "enable")) return Command{ .config = .{ .auto_switch = .{ .action = .enable } } };
                if (std.mem.eql(u8, action, "disable")) return Command{ .config = .{ .auto_switch = .{ .action = .disable } } };
            }

            var threshold_5h_percent: ?u8 = null;
            var threshold_weekly_percent: ?u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const arg = std.mem.sliceTo(args[i], 0);
                if (std.mem.eql(u8, arg, "--5h") and i + 1 < args.len) {
                    if (threshold_5h_percent != null) return Command{ .help = {} };
                    threshold_5h_percent = parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse return Command{ .help = {} };
                    i += 1;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--weekly") and i + 1 < args.len) {
                    if (threshold_weekly_percent != null) return Command{ .help = {} };
                    threshold_weekly_percent = parsePercentArg(std.mem.sliceTo(args[i + 1], 0)) orelse return Command{ .help = {} };
                    i += 1;
                    continue;
                }
                return Command{ .help = {} };
            }
            if (threshold_5h_percent == null and threshold_weekly_percent == null) return Command{ .help = {} };
            return Command{ .config = .{ .auto_switch = .{ .configure = .{
                .threshold_5h_percent = threshold_5h_percent,
                .threshold_weekly_percent = threshold_weekly_percent,
            } } } };
        }

        if (std.mem.eql(u8, scope, "api")) {
            if (args.len != 4) return Command{ .help = {} };
            const action = std.mem.sliceTo(args[3], 0);
            if (std.mem.eql(u8, action, "enable")) return Command{ .config = .{ .api_usage = .enable } };
            if (std.mem.eql(u8, action, "disable")) return Command{ .config = .{ .api_usage = .disable } };
        }

        return Command{ .help = {} };
    }

    if (std.mem.eql(u8, cmd, "daemon")) {
        if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--watch")) {
            return Command{ .daemon = .{ .mode = .watch } };
        }
        if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[2], 0), "--once")) {
            return Command{ .daemon = .{ .mode = .once } };
        }
        return Command{ .help = {} };
    }

    return Command{ .help = {} };
}

pub fn freeCommand(allocator: std.mem.Allocator, cmd: *Command) void {
    switch (cmd.*) {
        .import_auth => |*opts| {
            if (opts.auth_path) |path| allocator.free(path);
            if (opts.alias) |a| allocator.free(a);
        },
        .switch_account => |*opts| {
            if (opts.query) |e| allocator.free(e);
        },
        .remove_account => |*opts| {
            if (opts.query) |q| allocator.free(q);
        },
        else => {},
    }
}

pub fn printHelp(auto_cfg: *const registry.AutoSwitchConfig, api_cfg: *const registry.ApiConfig) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = colorEnabled();
    try writeHelp(out, use_color, auto_cfg, api_cfg);
    try out.flush();
    try printUsageApiRiskWarning(api_cfg.usage);
}

pub fn printUsageApiRiskWarning(api_usage_enabled: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    try writeUsageApiRiskWarning(out, stderrColorEnabled(), api_usage_enabled);
    try out.flush();
}

pub fn writeUsageApiRiskWarning(out: *std.Io.Writer, use_color: bool, api_usage_enabled: bool) !void {
    if (!api_usage_enabled) return;

    if (use_color) try out.writeAll(ansi.bold_yellow);
    try out.writeAll("Warning:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll(" Usage refresh is currently using the ChatGPT usage API and may trigger OpenAI account restrictions or suspension.\n");
    try out.writeAll("         Switch to local-only usage reading with `codex-auth config api disable` for safer but less accurate usage data.\n\n");
}

pub fn writeHelp(
    out: *std.Io.Writer,
    use_color: bool,
    auto_cfg: *const registry.AutoSwitchConfig,
    api_cfg: *const registry.ApiConfig,
) !void {
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
    try out.print(
        " {s} (5h<{d}%, weekly<{d}%)\n\n",
        .{ if (auto_cfg.enabled) "ON" else "OFF", auto_cfg.threshold_5h_percent, auto_cfg.threshold_weekly_percent },
    );

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Usage API:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.print(
        " {s} ({s})\n\n",
        .{ if (api_cfg.usage) "ON" else "OFF", if (api_cfg.usage) "api-only" else "local-sessions-only" },
    );

    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");

    const commands = [_]HelpEntry{
        .{ .name = "--version, -V", .description = "Show version" },
        .{ .name = "list", .description = "List available accounts" },
        .{ .name = "status", .description = "Show auto-switch and usage API status" },
        .{ .name = "login", .description = "Login and add the current account" },
        .{ .name = "import", .description = "Import auth files or rebuild registry" },
        .{ .name = "switch [<query>]", .description = "Switch the active account" },
        .{ .name = "remove [<query>|--all]", .description = "Remove one or more accounts" },
        .{ .name = "clean", .description = "Delete backup and stale files under accounts/" },
        .{ .name = "config", .description = "Manage configuration" },
    };
    const import_details = [_]HelpEntry{
        .{ .name = "<path>", .description = "Import one file or batch import a directory" },
        .{ .name = "--cpa [<path>]", .description = "Import CPA flat token JSON from one file or directory" },
        .{ .name = "--alias <alias>", .description = "Set alias for single-file import" },
        .{ .name = "--purge [<path>]", .description = "Rebuild `registry.json` from auth files" },
    };
    const config_details = [_]HelpEntry{
        .{ .name = "auto enable", .description = "Enable background auto-switching" },
        .{ .name = "auto disable", .description = "Disable background auto-switching" },
        .{ .name = "auto --5h <percent> [--weekly <percent>]", .description = "Configure auto-switch thresholds" },
        .{ .name = "api enable", .description = "Use usage API only" },
        .{ .name = "api disable", .description = "Use local sessions only" },
    };
    const parent_indent: usize = 2;
    const child_indent: usize = parent_indent + 4;
    const child_description_extra: usize = 4;
    const command_col = helpTargetColumn(&commands, parent_indent);
    const import_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&import_details, child_indent));
    const config_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&config_details, child_indent));

    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[0].name, commands[0].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[1].name, commands[1].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[2].name, commands[2].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[3].name, commands[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[4].name, commands[4].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[0].name, import_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[1].name, import_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[2].name, import_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[3].name, import_details[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[5].name, commands[5].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[6].name, commands[6].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[7].name, commands[7].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, commands[8].name, commands[8].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[0].name, config_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[1].name, config_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[2].name, config_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[3].name, config_details[3].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[4].name, config_details[4].description);

    try out.writeAll("\n");
    if (use_color) try out.writeAll(ansi.bold);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(ansi.reset);
    try out.writeAll("\n\n");
    try out.writeAll("  `add` is accepted as a deprecated alias for `login` and will be removed in the next release.\n");
}

fn parsePercentArg(raw: []const u8) ?u8 {
    const value = std.fmt.parseInt(u8, raw, 10) catch return null;
    if (value < 1 or value > 100) return null;
    return value;
}

const HelpEntry = struct {
    name: []const u8,
    description: []const u8,
};

fn helpTargetColumn(entries: []const HelpEntry, indent: usize) usize {
    var max_visible_len: usize = 0;
    for (entries) |entry| {
        max_visible_len = @max(max_visible_len, indent + entry.name.len);
    }
    return max_visible_len + 2;
}

fn writeHelpEntry(
    out: *std.Io.Writer,
    use_color: bool,
    indent: usize,
    target_col: usize,
    name: []const u8,
    description: []const u8,
) !void {
    if (use_color) try out.writeAll(ansi.bold_green);
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.writeAll(" ");
    }
    try out.print("{s}", .{name});
    if (use_color) try out.writeAll(ansi.reset);

    const visible_len = indent + name.len;
    const spaces = if (visible_len >= target_col) 2 else target_col - visible_len;
    i = 0;
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

pub fn printImportReport(report: *const registry.ImportReport) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try writeImportReport(stdout.out(), &stderr_writer.interface, report);
}

pub fn writeImportReport(
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    report: *const registry.ImportReport,
) !void {
    if (report.render_kind == .scanned) {
        try out.print("Scanning {s}...\n", .{report.source_label.?});
        try out.flush();
    }

    for (report.events.items) |event| {
        switch (event.outcome) {
            .imported => {
                try out.print("  ✓ imported  {s}\n", .{event.label});
                try out.flush();
            },
            .updated => {
                try out.print("  ✓ updated   {s}\n", .{event.label});
                try out.flush();
            },
            .skipped => {
                try err_out.print("  ✗ skipped   {s}: {s}\n", .{ event.label, event.reason.? });
                try err_out.flush();
            },
        }
    }

    if (report.render_kind == .scanned) {
        try out.print(
            "Import Summary: {d} imported, {d} updated, {d} skipped (total {d} {s})\n",
            .{
                report.imported,
                report.updated,
                report.skipped,
                report.total_files,
                if (report.total_files == 1) "file" else "files",
            },
        );
        try out.flush();
        return;
    }

    if (report.skipped > 0 and report.imported == 0 and report.updated == 0) {
        try out.print(
            "Import Summary: {d} imported, {d} skipped\n",
            .{ report.imported, report.skipped },
        );
        try out.flush();
    }
}

pub fn warnDeprecatedLoginAlias(opts: LoginOptions) void {
    if (opts.invocation != .add_alias) return;
    writeDeprecatedLoginAliasWarning("codex-auth login", stderrColorEnabled()) catch {};
}

fn writeDeprecatedLoginAliasWarning(replacement: []const u8, use_color: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    try writeDeprecatedLoginAliasWarningTo(out, replacement, use_color);
    try out.flush();
}

pub fn writeErrorPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold_red);
    try out.writeAll("error:");
    if (use_color) try out.writeAll(ansi.reset);
}

pub fn writeHintPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(ansi.bold_cyan);
    try out.writeAll("hint:");
    if (use_color) try out.writeAll(ansi.reset);
}

pub fn printAccountNotFoundError(query: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no account matches '{s}'.\n", .{query});
    try out.flush();
}

pub fn printRemoveRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive remove requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use `codex-auth remove <query>` or `codex-auth remove --all` instead.\n");
    try out.flush();
}

pub fn printInvalidRemoveSelectionError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" invalid remove selection input.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use numbers separated by commas or spaces, for example `1 2` or `1,2`.\n");
    try out.flush();
}

pub fn buildRemoveLabels(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !std.ArrayList([]const u8) {
    var labels = std.ArrayList([]const u8).empty;
    errdefer {
        for (labels.items) |label| allocator.free(@constCast(label));
        labels.deinit(allocator);
    }

    var display = try display_rows.buildDisplayRows(allocator, reg, indices);
    defer display.deinit(allocator);

    var current_header: ?[]const u8 = null;
    for (display.rows) |row| {
        if (row.account_index == null) {
            current_header = row.account_cell;
            continue;
        }

        const label = if (row.depth == 0 or current_header == null)
            try allocator.dupe(u8, row.account_cell)
        else
            try std.fmt.allocPrint(allocator, "{s} / {s}", .{ current_header.?, row.account_cell });
        try labels.append(allocator, label);
    }
    return labels;
}

fn writeMatchedAccountsListTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try out.writeAll("Matched multiple accounts:\n");
    for (labels) |label| {
        try out.print("- {s}\n", .{label});
    }
}

pub fn writeRemoveConfirmationTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try writeMatchedAccountsListTo(out, labels);
    try out.writeAll("Confirm delete? [y/N]: ");
}

pub fn printRemoveConfirmationUnavailableError(labels: []const []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    const use_color = stderrColorEnabled();
    try writeMatchedAccountsListTo(out, labels);
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" multiple accounts match the query in non-interactive mode.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Refine the query to match one account, or run the command in a TTY.\n");
    try out.flush();
}

pub fn confirmRemoveMatches(labels: []const []const u8) !bool {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeRemoveConfirmationTo(out, labels);
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    return line.len == 1 and (line[0] == 'y' or line[0] == 'Y');
}

pub fn writeRemoveSummaryTo(out: *std.Io.Writer, labels: []const []const u8) !void {
    try out.print("Removed {d} account(s): ", .{labels.len});
    for (labels, 0..) |label, idx| {
        if (idx != 0) try out.writeAll(", ");
        try out.writeAll(label);
    }
    try out.writeAll("\n");
}

pub fn printRemoveSummary(labels: []const []const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeRemoveSummaryTo(out, labels);
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

fn writeCodexLoginLaunchFailureHint(err_name: []const u8, use_color: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    const out = &writer.interface;
    try writeCodexLoginLaunchFailureHintTo(out, err_name, use_color);
    try out.flush();
}

pub fn writeCodexLoginLaunchFailureHintTo(out: *std.Io.Writer, err_name: []const u8, use_color: bool) !void {
    try writeErrorPrefixTo(out, use_color);
    if (std.mem.eql(u8, err_name, "FileNotFound")) {
        try out.writeAll(" the `codex` executable was not found in your PATH.\n\n");
        try writeHintPrefixTo(out, use_color);
        try out.writeAll(" Ensure the Codex CLI is installed and available in your environment.\n");
        try out.writeAll("      Then run `codex login` manually and retry your command.\n");
    } else {
        try out.writeAll(" failed to launch the `codex login` process.\n\n");
        try writeHintPrefixTo(out, use_color);
        try out.writeAll(" Try running `codex login` manually, then retry your command.\n");
    }
}

pub fn runCodexLogin(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var child = std.process.Child.init(&[_][]const u8{ "codex", "login" }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = child.spawnAndWait() catch |err| {
        writeCodexLoginLaunchFailureHint(@errorName(err), stderrColorEnabled()) catch {};
        return err;
    };
}

pub fn selectAccount(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    return if (comptime builtin.os.tag == .windows)
        selectWithNumbers(allocator, reg)
    else
        selectInteractive(allocator, reg) catch selectWithNumbers(allocator, reg);
}

pub fn selectAccountFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    if (indices.len == 0) return null;
    if (indices.len == 1) return reg.accounts.items[indices[0]].account_key;
    return if (comptime builtin.os.tag == .windows)
        selectWithNumbersFromIndices(allocator, reg, indices)
    else
        selectInteractiveFromIndices(allocator, reg, indices) catch selectWithNumbersFromIndices(allocator, reg, indices);
}

pub fn selectAccountsToRemove(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]usize {
    if (comptime builtin.os.tag == .windows) {
        return selectRemoveWithNumbers(allocator, reg);
    }
    if (shouldUseNumberedRemoveSelector(false, std.fs.File.stdin().isTty())) {
        return selectRemoveWithNumbers(allocator, reg);
    }
    return selectRemoveInteractive(allocator, reg) catch selectRemoveWithNumbers(allocator, reg);
}

pub fn shouldUseNumberedRemoveSelector(is_windows: bool, stdin_is_tty: bool) bool {
    return is_windows or !stdin_is_tty;
}

fn isQuitInput(input: []const u8) bool {
    return input.len == 1 and (input[0] == 'q' or input[0] == 'Q');
}

fn isQuitKey(key: u8) bool {
    return key == 'q' or key == 'Q';
}

fn activeSelectableIndex(rows: *const SwitchRows) ?usize {
    for (rows.selectable_row_indices, 0..) |row_idx, pos| {
        if (rows.items[row_idx].is_active) return pos;
    }
    return null;
}

fn accountIdForSelectable(rows: *const SwitchRows, reg: *registry.Registry, selectable_idx: usize) []const u8 {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    const account_idx = rows.items[row_idx].account_index.?;
    return reg.accounts.items[account_idx].account_key;
}

fn accountIndexForSelectable(rows: *const SwitchRows, selectable_idx: usize) usize {
    const row_idx = rows.selectable_row_indices[selectable_idx];
    return rows.items[row_idx].account_index.?;
}

fn selectWithNumbers(allocator: std.mem.Allocator, reg: *registry.Registry) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (reg.accounts.items.len == 0) return null;
    var rows = try buildSwitchRows(allocator, reg);
    defer rows.deinit(allocator);
    const use_color = colorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const idx = std.fmt.parseInt(usize, line, 10) catch return null;
    if (idx == 0 or idx > rows.selectable_row_indices.len) return null;
    return accountIdForSelectable(&rows, reg, idx - 1);
}

fn selectWithNumbersFromIndices(allocator: std.mem.Allocator, reg: *registry.Registry, indices: []const usize) !?[]const u8 {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (indices.len == 0) return null;

    var rows = try buildSwitchRowsFromIndices(allocator, reg, indices);
    defer rows.deinit(allocator);
    const use_color = colorEnabled();
    const active_idx = activeSelectableIndex(&rows);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    try out.writeAll("Select account to activate:\n\n");
    try renderSwitchList(out, reg, rows.items, idx_width, widths, active_idx, use_color);
    try out.writeAll("Select account number (or q to quit): ");
    try out.flush();

    var buf: [64]u8 = undefined;
    const n = try std.fs.File.stdin().read(&buf);
    const line = std.mem.trim(u8, buf[0..n], " \n\r\t");
    if (line.len == 0) {
        if (active_idx) |i| return accountIdForSelectable(&rows, reg, i);
        return null;
    }
    if (isQuitInput(line)) return null;
    const idx = std.fmt.parseInt(usize, line, 10) catch return null;
    if (idx == 0 or idx > rows.selectable_row_indices.len) return null;
    return accountIdForSelectable(&rows, reg, idx - 1);
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
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    while (true) {
        try out.writeAll("\x1b[2J\x1b[H");
        try out.writeAll("Select account to activate:\n\n");
        try renderSwitchList(out, reg, rows.items, idx_width, widths, idx, use_color);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll("Keys: ↑/↓ or j/k, Enter select, 1-9 type, Backspace edit, Esc or q quit\n");
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
                    } else if (code == 'B' and idx + 1 < rows.selectable_row_indices.len) {
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
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                        return accountIdForSelectable(&rows, reg, parsed - 1);
                    }
                }
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;

            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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
    var rows = try buildSwitchRows(allocator, reg);
    defer rows.deinit(allocator);
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
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
    if (!isStrictRemoveSelectionLine(line)) return error.InvalidRemoveSelectionInput;

    var current: usize = 0;
    var in_number = false;
    for (line) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + @as(usize, ch - '0');
            in_number = true;
            continue;
        }
        if (in_number) {
            if (current >= 1 and current <= rows.selectable_row_indices.len) {
                checked[current - 1] = true;
            }
            current = 0;
            in_number = false;
        }
    }
    if (in_number and current >= 1 and current <= rows.selectable_row_indices.len) {
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
        selected[idx] = accountIndexForSelectable(&rows, i);
        idx += 1;
    }
    return selected;
}

fn isStrictRemoveSelectionLine(line: []const u8) bool {
    for (line) |ch| {
        if ((ch >= '0' and ch <= '9') or ch == ',' or ch == ' ' or ch == '\t') continue;
        return false;
    }
    return true;
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
    const active_idx = activeSelectableIndex(&rows);
    var idx: usize = active_idx orelse 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const widths = rows.widths;

    while (true) {
        try out.writeAll("\x1b[2J\x1b[H");
        try out.writeAll("Select account to activate:\n\n");
        try renderSwitchList(out, reg, rows.items, idx_width, widths, idx, use_color);
        try out.writeAll("\n");
        if (use_color) try out.writeAll(ansi.dim);
        try out.writeAll("Keys: ↑/↓ or j/k, Enter select, 1-9 type, Backspace edit, Esc or q quit\n");
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
                    } else if (code == 'B' and idx + 1 < rows.selectable_row_indices.len) {
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
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
                        return accountIdForSelectable(&rows, reg, parsed - 1);
                    }
                }
                return accountIdForSelectable(&rows, reg, idx);
            }
            if (isQuitKey(b[i])) return null;
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < rows.selectable_row_indices.len) {
                idx += 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 0x7f or b[i] == 0x08) {
                if (number_len > 0) {
                    number_len -= 1;
                    if (number_len > 0) {
                        const parsed = std.fmt.parseInt(usize, number_buf[0..number_len], 10) catch 0;
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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

    var checked = try allocator.alloc(bool, rows.selectable_row_indices.len);
    defer allocator.free(checked);
    @memset(checked, false);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    var idx: usize = 0;
    var number_buf: [8]u8 = undefined;
    var number_len: usize = 0;
    const use_color = colorEnabled();
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
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
                    } else if (code == 'B' and idx + 1 < rows.selectable_row_indices.len) {
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
                    selected[out_idx] = accountIndexForSelectable(&rows, sel_idx);
                    out_idx += 1;
                }
                return selected;
            }
            if (b[i] == 'k' and idx > 0) {
                idx -= 1;
                number_len = 0;
                continue;
            }
            if (b[i] == 'j' and idx + 1 < rows.selectable_row_indices.len) {
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
                        if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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
                    if (parsed >= 1 and parsed <= rows.selectable_row_indices.len) {
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
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var selectable_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            continue;
        }

        const is_selected = selected != null and selected.? == selectable_counter;
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
        try writeIndexPadded(out, selectable_counter + 1, idx_width);
        try out.writeAll(" ");
        try writeTruncatedPadded(out, row.account, widths.email);
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
        selectable_counter += 1;
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
    try writePadded(out, "ACCOUNT", widths.email);
    try out.writeAll("  ");
    try writePadded(out, "PLAN", widths.plan);
    try out.writeAll("  ");
    try writePadded(out, "5H", widths.rate_5h);
    try out.writeAll("  ");
    try writePadded(out, "WEEKLY", widths.rate_week);
    try out.writeAll("  ");
    try writePadded(out, "LAST", widths.last);
    try out.writeAll("\n");

    var selectable_counter: usize = 0;
    for (rows) |row| {
        if (row.is_header) {
            if (use_color) try out.writeAll(ansi.dim);
            try out.writeAll("  ");
            var pad_header: usize = 0;
            while (pad_header < checkbox_width + 1 + idx_width + 1) : (pad_header += 1) {
                try out.writeAll(" ");
            }
            try writeTruncatedPadded(out, row.account, widths.email);
            try out.writeAll("\n");
            if (use_color) try out.writeAll(ansi.reset);
            continue;
        }

        const is_cursor = cursor != null and cursor.? == selectable_counter;
        const is_checked = checked[selectable_counter];
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
        try writeIndexPadded(out, selectable_counter + 1, idx_width);
        try out.writeAll(" ");
        try writeTruncatedPadded(out, row.account, widths.email);
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
        selectable_counter += 1;
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
    account_index: ?usize,
    account: []u8,
    plan: []const u8,
    rate_5h: []u8,
    rate_week: []u8,
    last: []u8,
    is_active: bool,
    is_header: bool,

    fn deinit(self: *SwitchRow, allocator: std.mem.Allocator) void {
        allocator.free(self.account);
        allocator.free(self.rate_5h);
        allocator.free(self.rate_week);
        allocator.free(self.last);
    }
};

const SwitchRows = struct {
    items: []SwitchRow,
    selectable_row_indices: []usize,
    widths: SwitchWidths,

    fn deinit(self: *SwitchRows, allocator: std.mem.Allocator) void {
        for (self.items) |*row| row.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.selectable_row_indices);
    }
};

fn buildSwitchRows(allocator: std.mem.Allocator, reg: *registry.Registry) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, null);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.time.timestamp();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = if (registry.resolvePlan(&rec)) |p| @tagName(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const rate_5h_str = try formatRateLimitSwitchAlloc(allocator, rate_5h);
            const rate_week_str = try formatRateLimitSwitchAlloc(allocator, rate_week);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .is_active = display_row.is_active,
                .is_header = false,
            };
            widths.email = @max(widths.email, display_row.account_cell.len);
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .is_active = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, display_row.account_cell.len);
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
}

fn buildSwitchRowsFromIndices(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    indices: []const usize,
) !SwitchRows {
    var display = try display_rows.buildDisplayRows(allocator, reg, indices);
    defer display.deinit(allocator);
    var rows = try allocator.alloc(SwitchRow, display.rows.len);
    var widths = SwitchWidths{
        .email = "EMAIL".len,
        .plan = "PLAN".len,
        .rate_5h = "5H".len,
        .rate_week = "WEEKLY".len,
        .last = "LAST".len,
    };
    const now = std.time.timestamp();
    for (display.rows, 0..) |display_row, i| {
        if (display_row.account_index) |account_idx| {
            const rec = reg.accounts.items[account_idx];
            const plan = if (registry.resolvePlan(&rec)) |p| @tagName(p) else "-";
            const rate_5h = resolveRateWindow(rec.last_usage, 300, true);
            const rate_week = resolveRateWindow(rec.last_usage, 10080, false);
            const rate_5h_str = try formatRateLimitSwitchAlloc(allocator, rate_5h);
            const rate_week_str = try formatRateLimitSwitchAlloc(allocator, rate_week);
            const last = try timefmt.formatRelativeTimeOrDashAlloc(allocator, rec.last_usage_at, now);
            rows[i] = .{
                .account_index = account_idx,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = plan,
                .rate_5h = rate_5h_str,
                .rate_week = rate_week_str,
                .last = last,
                .is_active = display_row.is_active,
                .is_header = false,
            };
            widths.email = @max(widths.email, display_row.account_cell.len);
            widths.plan = @max(widths.plan, plan.len);
            widths.rate_5h = @max(widths.rate_5h, rate_5h_str.len);
            widths.rate_week = @max(widths.rate_week, rate_week_str.len);
            widths.last = @max(widths.last, last.len);
        } else {
            rows[i] = .{
                .account_index = null,
                .account = try allocator.dupe(u8, display_row.account_cell),
                .plan = "",
                .rate_5h = try allocator.dupe(u8, ""),
                .rate_week = try allocator.dupe(u8, ""),
                .last = try allocator.dupe(u8, ""),
                .is_active = false,
                .is_header = true,
            };
            widths.email = @max(widths.email, display_row.account_cell.len);
        }
    }
    if (widths.email > 32) widths.email = 32;
    return SwitchRows{
        .items = rows,
        .selectable_row_indices = try allocator.dupe(usize, display.selectable_row_indices),
        .widths = widths,
    };
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

test "Scenario: Given q quit input when checking switch picker helpers then both line and key shortcuts cancel selection" {
    try std.testing.expect(isQuitInput("q"));
    try std.testing.expect(isQuitInput("Q"));
    try std.testing.expect(!isQuitInput(""));
    try std.testing.expect(!isQuitInput("1"));
    try std.testing.expect(!isQuitInput("qq"));
    try std.testing.expect(isQuitKey('q'));
    try std.testing.expect(isQuitKey('Q'));
    try std.testing.expect(!isQuitKey('j'));
}
