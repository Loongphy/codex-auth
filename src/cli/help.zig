const std = @import("std");
const registry = @import("../registry/root.zig");
const io_util = @import("../core/io_util.zig");
const version = @import("../version.zig");
const types = @import("types.zig");
const style = @import("style.zig");

const HelpTopic = types.HelpTopic;

pub fn printHelp(auto_cfg: *const registry.AutoSwitchConfig, api_cfg: *const registry.ApiConfig) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = style.stdoutColorEnabled();
    try writeHelp(out, use_color, auto_cfg, api_cfg);
    try out.flush();
}

pub fn writeHelp(
    out: *std.Io.Writer,
    use_color: bool,
    auto_cfg: *const registry.AutoSwitchConfig,
    api_cfg: *const registry.ApiConfig,
) !void {
    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("codex-auth");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll(" ");
    if (use_color) try out.writeAll(style.ansi.dim);
    try out.writeAll(version.app_version);
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n\n");

    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("Auto Switch:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s} (5h<{d}%, weekly<{d}%)\n\n",
        .{ if (auto_cfg.enabled) "ON" else "OFF", auto_cfg.threshold_5h_percent, auto_cfg.threshold_weekly_percent },
    );

    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("Usage API:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s} ({s})\n\n",
        .{ if (api_cfg.usage) "ON" else "OFF", if (api_cfg.usage) "api" else "local" },
    );

    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("Account API:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s}\n\n",
        .{if (api_cfg.account) "ON" else "OFF"},
    );

    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n\n");

    const command_entries = [_]HelpEntry{
        .{ .name = "--version, -V", .description = "Show version" },
        .{ .name = "list", .description = "List available accounts" },
        .{ .name = "status", .description = "Show auto-switch and usage API status" },
        .{ .name = "login", .description = "Login and add the current account" },
        .{ .name = "import", .description = "Import auth files or rebuild registry" },
        .{ .name = "switch [--live] [--auto] [--api|--skip-api] | switch <query>", .description = "Switch the active account" },
        .{ .name = "remove [--live] [--api|--skip-api] | remove <query> [<query>...] | remove --all", .description = "Remove one or more accounts" },
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
        .{ .name = "api enable", .description = "Enable usage and account APIs" },
        .{ .name = "api disable", .description = "Disable usage and account APIs" },
    };
    const parent_indent: usize = 2;
    const child_indent: usize = parent_indent + 4;
    const child_description_extra: usize = 4;
    const command_col = helpTargetColumn(&command_entries, parent_indent);
    const import_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&import_details, child_indent));
    const config_detail_col = @max(command_col + child_description_extra, helpTargetColumn(&config_details, child_indent));

    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[0].name, command_entries[0].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[1].name, command_entries[1].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[2].name, command_entries[2].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[3].name, command_entries[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[4].name, command_entries[4].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[0].name, import_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[1].name, import_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[2].name, import_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, import_detail_col, import_details[3].name, import_details[3].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[5].name, command_entries[5].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[6].name, command_entries[6].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[7].name, command_entries[7].description);
    try writeHelpEntry(out, use_color, parent_indent, command_col, command_entries[8].name, command_entries[8].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[0].name, config_details[0].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[1].name, config_details[1].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[2].name, config_details[2].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[3].name, config_details[3].description);
    try writeHelpEntry(out, use_color, child_indent, config_detail_col, config_details[4].name, config_details[4].description);

    try out.writeAll("\n");
    if (use_color) try out.writeAll(style.ansi.bold);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n\n");
    try out.writeAll("  Run `codex-auth <command> --help` for command-specific usage details.\n");
    try out.writeAll("  `config api enable` may trigger OpenAI account restrictions or suspension in some environments.\n");
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
    if (use_color) try out.writeAll(style.ansi.bold_green);
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.writeAll(" ");
    }
    try out.print("{s}", .{name});
    if (use_color) try out.writeAll(style.ansi.reset);

    const visible_len = indent + name.len;
    const spaces = if (visible_len >= target_col) 2 else target_col - visible_len;
    i = 0;
    while (i < spaces) : (i += 1) {
        try out.writeAll(" ");
    }

    try out.writeAll(description);
    try out.writeAll("\n");
}

pub fn printCommandHelp(topic: HelpTopic) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCommandHelp(out, style.stdoutColorEnabled(), topic);
    try out.flush();
}

pub fn writeCommandHelp(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeCommandHelpHeader(out, use_color, topic);
    try out.writeAll("\n");
    try writeUsageSection(out, topic);
    if (commandHelpHasExamples(topic)) {
        try out.writeAll("\n\n");
        try writeExamplesSection(out, topic);
    }
}

fn writeCommandHelpHeader(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    if (use_color) try out.writeAll(style.ansi.bold);
    try out.print("codex-auth {s}", .{commandNameForTopic(topic)});
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");
    try out.print("{s}\n", .{commandDescriptionForTopic(topic)});
}

fn commandNameForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "",
        .list => "list",
        .status => "status",
        .login => "login",
        .import_auth => "import",
        .switch_account => "switch",
        .remove_account => "remove",
        .clean => "clean",
        .config => "config",
        .daemon => "daemon",
    };
}

fn commandDescriptionForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "Command-line account management for Codex.",
        .list => "List available accounts.",
        .status => "Show auto-switch, service, and usage API status.",
        .login => "Run `codex login` or `codex login --device-auth`, then add the current account.",
        .import_auth => "Import auth files or rebuild the registry.",
        .switch_account => "Switch the active account interactively, or by query using stored local data.",
        .remove_account => "Remove one or more accounts interactively or by query.",
        .clean => "Delete backup and stale files under accounts/.",
        .config => "Manage auto-switch and usage API configuration.",
        .daemon => "Run the background auto-switch daemon.",
    };
}

fn commandHelpHasExamples(topic: HelpTopic) bool {
    return switch (topic) {
        .import_auth, .switch_account, .remove_account, .config, .daemon => true,
        else => false,
    };
}

pub fn writeUsageSection(out: *std.Io.Writer, topic: HelpTopic) !void {
    try out.writeAll("Usage:\n");
    switch (topic) {
        .top_level => {
            try out.writeAll("  codex-auth <command>\n");
            try out.writeAll("  codex-auth --help\n");
            try out.writeAll("  codex-auth help <command>\n");
        },
        .list => try out.writeAll("  codex-auth list [--live] [--api|--skip-api]\n"),
        .status => try out.writeAll("  codex-auth status\n"),
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import <path> [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --cpa [<path>] [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --purge [<path>]\n");
        },
        .switch_account => {
            try out.writeAll("  codex-auth switch [--live] [--auto] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth switch <query>\n");
        },
        .remove_account => {
            try out.writeAll("  codex-auth remove [--live] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth remove <query> [<query>...]\n");
            try out.writeAll("  codex-auth remove --all\n");
        },
        .clean => try out.writeAll("  codex-auth clean\n"),
        .config => {
            try out.writeAll("  codex-auth config auto enable\n");
            try out.writeAll("  codex-auth config auto disable\n");
            try out.writeAll("  codex-auth config auto --5h <percent> [--weekly <percent>]\n");
            try out.writeAll("  codex-auth config auto --weekly <percent>\n");
            try out.writeAll("  codex-auth config api enable\n");
            try out.writeAll("  codex-auth config api disable\n");
        },
        .daemon => {
            try out.writeAll("  codex-auth daemon --watch\n");
            try out.writeAll("  codex-auth daemon --once\n");
        },
    }
}

pub fn helpCommandForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "codex-auth --help",
        .list => "codex-auth list --help",
        .status => "codex-auth status --help",
        .login => "codex-auth login --help",
        .import_auth => "codex-auth import --help",
        .switch_account => "codex-auth switch --help",
        .remove_account => "codex-auth remove --help",
        .clean => "codex-auth clean --help",
        .config => "codex-auth config --help",
        .daemon => "codex-auth daemon --help",
    };
}

fn writeExamplesSection(out: *std.Io.Writer, topic: HelpTopic) !void {
    try out.writeAll("Examples:\n");
    switch (topic) {
        .top_level => {
            try out.writeAll("  codex-auth list\n");
            try out.writeAll("  codex-auth import /path/to/auth.json --alias personal\n");
            try out.writeAll("  codex-auth config auto enable\n");
        },
        .list => {
            try out.writeAll("  codex-auth list\n");
            try out.writeAll("  codex-auth list --live\n");
            try out.writeAll("  codex-auth list --api\n");
            try out.writeAll("  codex-auth list --skip-api\n");
        },
        .status => try out.writeAll("  codex-auth status\n"),
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import /path/to/auth.json --alias personal\n");
            try out.writeAll("  codex-auth import --cpa /path/to/token.json --alias work\n");
            try out.writeAll("  codex-auth import --purge\n");
        },
        .switch_account => {
            try out.writeAll("  codex-auth switch\n");
            try out.writeAll("  codex-auth switch --live\n");
            try out.writeAll("  codex-auth switch --live --auto\n");
            try out.writeAll("  codex-auth switch --api\n");
            try out.writeAll("  codex-auth switch --skip-api\n");
            try out.writeAll("  codex-auth switch work\n");
            try out.writeAll("  codex-auth switch 02\n");
        },
        .remove_account => {
            try out.writeAll("  codex-auth remove\n");
            try out.writeAll("  codex-auth remove --live\n");
            try out.writeAll("  codex-auth remove --api\n");
            try out.writeAll("  codex-auth remove --skip-api\n");
            try out.writeAll("  codex-auth remove 01 03\n");
            try out.writeAll("  codex-auth remove work personal\n");
            try out.writeAll("  codex-auth remove john@example.com jane@example.com\n");
            try out.writeAll("  codex-auth remove --all\n");
        },
        .clean => try out.writeAll("  codex-auth clean\n"),
        .config => {
            try out.writeAll("  codex-auth config auto --5h 12 --weekly 8\n");
            try out.writeAll("  codex-auth config api enable\n");
        },
        .daemon => {
            try out.writeAll("  codex-auth daemon --watch\n");
            try out.writeAll("  codex-auth daemon --once\n");
        },
    }
}
