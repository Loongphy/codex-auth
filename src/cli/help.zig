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
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("codex-auth");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll(" ");
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll(version.app_version);
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n\n");

    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Auto Switch:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s} (5h<{d}%, weekly<{d}%)\n",
        .{ if (auto_cfg.enabled) "ON" else "OFF", auto_cfg.threshold_5h_percent, auto_cfg.threshold_weekly_percent },
    );

    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Usage API:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s} ({s})\n",
        .{ if (api_cfg.usage) "ON" else "OFF", if (api_cfg.usage) "api" else "local" },
    );

    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Account API:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.print(
        " {s}\n\n",
        .{if (api_cfg.account) "ON" else "OFF"},
    );

    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");

    try writeCommandSummary(out, use_color, "--help, -h", "Show this help");
    try writeCommandSummary(out, use_color, "help <command>", "Show command-specific help");
    try writeCommandSummary(out, use_color, "--version, -V", "Show version");
    try writeCommandSummary(out, use_color, "list [--live] [--api|--skip-api]", "List available accounts");
    try writeCommandSummary(out, use_color, "status", "Show auto-switch, service, and usage API status");
    try writeCommandSummary(out, use_color, "login [--device-auth]", "Login and add the current account");
    try writeCommandSummary(out, use_color, "import", "Import auth files or rebuild registry");
    try writeCommandDetail(out, use_color, "import <path> [--alias <alias>]");
    try writeCommandDetail(out, use_color, "import --cpa [<path>] [--alias <alias>]");
    try writeCommandDetail(out, use_color, "import --purge [<path>]");
    try writeCommandSummary(out, use_color, "switch", "Switch the active account");
    try writeCommandDetail(out, use_color, "switch [--live] [--api|--skip-api]");
    try writeCommandDetail(out, use_color, "switch <alias|email|display-number|query>");
    try writeCommandSummary(out, use_color, "remove", "Remove one or more accounts");
    try writeCommandDetail(out, use_color, "remove [--live] [--api|--skip-api]");
    try writeCommandDetail(out, use_color, "remove <alias|email|display-number|query>...");
    try writeCommandDetail(out, use_color, "remove --all");
    try writeCommandSummary(out, use_color, "clean", "Delete backup and stale files under accounts/");
    try writeCommandSummary(out, use_color, "config", "Manage configuration");
    try writeCommandDetail(out, use_color, "config auto enable");
    try writeCommandDetail(out, use_color, "config auto disable");
    try writeCommandDetail(out, use_color, "config auto --5h <percent> [--weekly <percent>]");
    try writeCommandDetail(out, use_color, "config auto --weekly <percent>");
    try writeCommandDetail(out, use_color, "config api enable");
    try writeCommandDetail(out, use_color, "config api disable");
    try writeCommandDetail(out, use_color, "config live --interval <seconds>");
    try writeCommandSummary(out, use_color, "daemon --watch|--once", "Run the background auto-switch daemon");

    try out.writeAll("\n");
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");
    try out.writeAll("  Run `codex-auth <command> --help` for command-specific usage details.\n");
    try out.writeAll("  `config api enable` may trigger OpenAI account restrictions or suspension in some environments.\n");
}

fn writeCommandSummary(out: *std.Io.Writer, use_color: bool, command: []const u8, description: []const u8) !void {
    try out.writeAll("  ");
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll(command);
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n      ");
    try out.writeAll(description);
    try out.writeAll("\n");
}

fn writeCommandDetail(out: *std.Io.Writer, use_color: bool, command: []const u8) !void {
    try out.writeAll("      ");
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll(command);
    if (use_color) try out.writeAll(style.ansi.reset);
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
    try writeUsageSectionStyled(out, use_color, topic);
    if (commandHelpHasOptions(topic)) {
        try out.writeAll("\n\n");
        try writeOptionsSectionStyled(out, use_color, topic);
    }
    if (commandHelpHasExamples(topic)) {
        try out.writeAll("\n\n");
        try writeExamplesSectionStyled(out, use_color, topic);
    }
    if (commandHelpHasNotes(topic)) {
        try out.writeAll("\n\n");
        try writeNotesSectionStyled(out, use_color, topic);
    }
}

fn writeCommandHelpHeader(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    if (use_color) try out.writeAll(style.ansi.cyan);
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
        .switch_account => "Switch the active account by alias, email, display number, or partial query.",
        .remove_account => "Remove one or more accounts by alias, email, display number, or partial query.",
        .clean => "Delete backup and stale files under accounts/.",
        .config => "Manage auto-switch, API, and live refresh configuration.",
        .daemon => "Run the background auto-switch daemon.",
    };
}

fn commandHelpHasExamples(topic: HelpTopic) bool {
    return switch (topic) {
        .import_auth, .switch_account, .remove_account, .config, .daemon => true,
        else => false,
    };
}

fn commandHelpHasOptions(topic: HelpTopic) bool {
    return switch (topic) {
        .list, .login, .import_auth, .switch_account, .remove_account, .config, .daemon => true,
        else => false,
    };
}

fn commandHelpHasNotes(topic: HelpTopic) bool {
    return switch (topic) {
        else => false,
    };
}

pub fn writeUsageSection(out: *std.Io.Writer, topic: HelpTopic) !void {
    try writeUsageSectionStyled(out, false, topic);
}

pub fn writeUsageSectionStyled(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeSectionTitle(out, use_color, "Usage:");
    try out.writeAll("\n");
    try writeUsageLines(out, topic);
}

fn writeUsageLines(out: *std.Io.Writer, topic: HelpTopic) !void {
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
            try out.writeAll("  codex-auth switch [--live] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth switch <alias|email|display-number|query>\n");
        },
        .remove_account => {
            try out.writeAll("  codex-auth remove [--live] [--api|--skip-api]\n");
            try out.writeAll("  codex-auth remove <alias|email|display-number|query>...\n");
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
            try out.writeAll("  codex-auth config live --interval <seconds>\n");
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

fn writeOptionsSectionStyled(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeSectionTitle(out, use_color, "Options:");
    try out.writeAll("\n");
    try writeOptionLines(out, topic);
}

fn writeOptionLines(out: *std.Io.Writer, topic: HelpTopic) !void {
    switch (topic) {
        .list => {
            try out.writeAll("  --live       Open a live-updating table.\n");
            try out.writeAll("  --api        Load usage and account data from APIs.\n");
            try out.writeAll("  --skip-api   Load usage and account data from local data only (may be inaccurate).\n");
        },
        .login => {
            try out.writeAll("  --device-auth   Run `codex login --device-auth` before adding the account.\n");
        },
        .import_auth => {
            try out.writeAll("  <path>           Import one auth file or every supported auth file in a directory.\n");
            try out.writeAll("  --cpa [<path>]   Import CPA flat token JSON from a file or directory. Uses `~/.cli-proxy-api` when omitted.\n");
            try out.writeAll("  --alias <alias>  Set an alias for a single imported account.\n");
            try out.writeAll("  --purge [<path>] Rebuild `registry.json` from auth files. Uses the accounts directory when omitted.\n");
        },
        .switch_account => {
            try out.writeAll("  --live       Open the live switch UI.\n");
            try out.writeAll("  --api        Load usage and account data from APIs.\n");
            try out.writeAll("  --skip-api   Load usage and account data from local data only (may be inaccurate).\n");
            try out.writeAll("  <alias|email|display-number|query>\n");
            try out.writeAll("               Switch directly when the target resolves to one account.\n");
        },
        .remove_account => {
            try out.writeAll("  --live       Open the live remove UI.\n");
            try out.writeAll("  --api        Load usage and account data from APIs.\n");
            try out.writeAll("  --skip-api   Load usage and account data from local data only (may be inaccurate).\n");
            try out.writeAll("  --all        Remove every stored account.\n");
            try out.writeAll("  <alias|email|display-number|query>...\n");
            try out.writeAll("               Remove one or more matching accounts.\n");
        },
        .config => {
            try out.writeAll("  auto enable       Enable background auto-switching.\n");
            try out.writeAll("  auto disable      Disable background auto-switching.\n");
            try out.writeAll("  --5h <percent>    Set the 5-hour usage threshold from 1 to 100.\n");
            try out.writeAll("  --weekly <percent>\n");
            try out.writeAll("                    Set the weekly usage threshold from 1 to 100.\n");
            try out.writeAll("  api enable        Enable usage and account APIs.\n");
            try out.writeAll("  api disable       Disable usage and account APIs.\n");
            try out.writeAll("  live --interval <seconds>\n");
            try out.writeAll("                    Set the live TUI refresh interval from 5 to 3600 seconds.\n");
        },
        .daemon => {
            try out.writeAll("  --watch   Run continuously and switch accounts when thresholds are reached.\n");
            try out.writeAll("  --once    Run one auto-switch check, then exit.\n");
        },
        else => {},
    }
}

fn writeExamplesSectionStyled(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeSectionTitle(out, use_color, "Examples:");
    try out.writeAll("\n");
    try writeExampleLines(out, topic);
}

fn writeExampleLines(out: *std.Io.Writer, topic: HelpTopic) !void {
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
            try out.writeAll("  codex-auth switch --api\n");
            try out.writeAll("  codex-auth switch --skip-api\n");
            try out.writeAll("  codex-auth switch personal\n");
            try out.writeAll("  codex-auth switch john@example.com\n");
            try out.writeAll("  codex-auth switch 02\n");
            try out.writeAll("  codex-auth switch work\n");
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
            try out.writeAll("  codex-auth config live --interval 30\n");
        },
        .daemon => {
            try out.writeAll("  codex-auth daemon --watch\n");
            try out.writeAll("  codex-auth daemon --once\n");
        },
    }
}

fn writeNotesSectionStyled(out: *std.Io.Writer, use_color: bool, topic: HelpTopic) !void {
    try writeSectionTitle(out, use_color, "Notes:");
    try out.writeAll("\n");
    switch (topic) {
        .switch_account => {
            try out.writeAll("  Targets can be aliases, emails, display numbers, or partial queries.\n");
        },
        else => {},
    }
}

fn writeSectionTitle(out: *std.Io.Writer, use_color: bool, title: []const u8) !void {
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll(title);
    if (use_color) try out.writeAll(style.ansi.reset);
}
