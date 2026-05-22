const std = @import("std");
const io_util = @import("../core/io_util.zig");
const version = @import("../version.zig");
const types = @import("types.zig");
const style = @import("style.zig");

const HelpTopic = types.HelpTopic;

pub fn printHelp() !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = stdout.color_enabled;
    try writeHelp(out, use_color);
    try out.flush();
}

pub fn writeHelp(
    out: *std.Io.Writer,
    use_color: bool,
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
    try out.writeAll("Commands:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");

    try writeCommandSummary(out, use_color, "--help, -h", "Show this help");
    try writeCommandSummary(out, use_color, "help <command>", "Show command-specific help");
    try writeCommandSummary(out, use_color, "--version, -V", "Show version");
    try writeCommandSummary(out, use_color, "list [--live] [--active] [--api|--skip-api]", "List available accounts");
    try writeCommandSummary(out, use_color, "login [--device-auth]", "Login and add the current account");
    try writeCommandSummary(out, use_color, "import", "Import auth files or rebuild registry");
    try writeCommandDetail(out, use_color, "import <path> [--alias <alias>]");
    try writeCommandDetail(out, use_color, "import --cpa [<path>] [--alias <alias>]");
    try writeCommandDetail(out, use_color, "import --purge [<path>]");
    try writeCommandSummary(out, use_color, "export [<dir>] [--cpa]", "Export stored account auth files");
    try writeCommandSummary(out, use_color, "switch", "Switch the active account");
    try writeCommandDetail(out, use_color, "switch [--live] [--api|--skip-api]");
    try writeCommandDetail(out, use_color, "switch <alias|email|display-number|query>");
    try writeCommandSummary(out, use_color, "remove", "Remove one or more accounts");
    try writeCommandDetail(out, use_color, "remove [--live] [--api|--skip-api]");
    try writeCommandDetail(out, use_color, "remove <alias|email|display-number|query>...");
    try writeCommandDetail(out, use_color, "remove --all");
    try writeCommandSummary(out, use_color, "alias", "Set or clear account aliases");
    try writeCommandDetail(out, use_color, "alias set <alias|email|display-number|query> <alias>");
    try writeCommandDetail(out, use_color, "alias clear <alias|email|display-number|query>");
    try writeCommandSummary(out, use_color, "clean", "Delete backup and stale files under accounts/");
    try writeCommandDetail(out, use_color, "clean background");
    try writeCommandSummary(out, use_color, "config", "Manage configuration");
    try writeCommandDetail(out, use_color, "config live --interval <seconds>");
    try writeCommandSummary(out, use_color, "app", "Launch Codex App with CLI overrides");

    try out.writeAll("\n");
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("Notes:");
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.writeAll("\n");
    try out.writeAll("  Run `codex-auth <command> --help` for command-specific usage details.\n");
    try out.writeAll("  API-backed refresh is the default; use `--skip-api` for a local-only foreground command.\n");
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
    try writeCommandHelp(out, stdout.color_enabled, topic);
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
        .login => "login",
        .import_auth => "import",
        .export_auth => "export",
        .switch_account => "switch",
        .remove_account => "remove",
        .alias => "alias",
        .clean => "clean",
        .config => "config",
        .app => "app",
    };
}

fn commandDescriptionForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "Command-line account management for Codex.",
        .list => "List available accounts.",
        .login => "Run `codex login` or `codex login --device-auth`, then add the current account.",
        .import_auth => "Import auth files or rebuild the registry.",
        .export_auth => "Export stored account auth files.",
        .switch_account => "Switch the active account by alias, email, display number, or partial query.",
        .remove_account => "Remove one or more accounts by alias, email, display number, or partial query.",
        .alias => "Set or clear an account alias by alias, email, display number, or partial query.",
        .clean => "Delete backup and stale files under accounts/.",
        .config => "Manage live refresh configuration.",
        .app => "Launch Codex App with CLI overrides.",
    };
}

fn commandHelpHasExamples(topic: HelpTopic) bool {
    return switch (topic) {
        .import_auth, .export_auth, .switch_account, .remove_account, .alias, .config, .app => true,
        else => false,
    };
}

fn commandHelpHasOptions(topic: HelpTopic) bool {
    return switch (topic) {
        .list, .login, .import_auth, .export_auth, .switch_account, .remove_account, .alias, .config, .app => true,
        else => false,
    };
}

fn commandHelpHasNotes(topic: HelpTopic) bool {
    return switch (topic) {
        .switch_account, .alias => true,
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
        .list => try out.writeAll("  codex-auth list [--live] [--active] [--api|--skip-api]\n"),
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import <path> [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --cpa [<path>] [--alias <alias>]\n");
            try out.writeAll("  codex-auth import --purge [<path>]\n");
        },
        .export_auth => {
            try out.writeAll("  codex-auth export [<dir>]\n");
            try out.writeAll("  codex-auth export --cpa [<dir>]\n");
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
        .alias => {
            try out.writeAll("  codex-auth alias set <alias|email|display-number|query> <alias>\n");
            try out.writeAll("  codex-auth alias clear <alias|email|display-number|query>\n");
        },
        .clean => {
            try out.writeAll("  codex-auth clean\n");
            try out.writeAll("  codex-auth clean background\n");
        },
        .config => {
            try out.writeAll("  codex-auth config live --interval <seconds>\n");
        },
        .app => {
            try out.writeAll("  codex-auth app [--id <id>] [--codex-cli-path <path>] [--codex-home <path>] [--platform win|wsl|mac]\n");
        },
    }
}

pub fn helpCommandForTopic(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .top_level => "codex-auth --help",
        .list => "codex-auth list --help",
        .login => "codex-auth login --help",
        .import_auth => "codex-auth import --help",
        .export_auth => "codex-auth export --help",
        .switch_account => "codex-auth switch --help",
        .remove_account => "codex-auth remove --help",
        .alias => "codex-auth alias --help",
        .clean => "codex-auth clean --help",
        .config => "codex-auth config --help",
        .app => "codex-auth app --help",
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
            try out.writeAll("  --active     Refresh only the active account before rendering.\n");
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
        .export_auth => {
            try out.writeAll("  <dir>   Directory to write exported account files. Uses `CODEX_HOME/accounts/backup` when omitted.\n");
            try out.writeAll("  --cpa   Export CPA flat token JSON. Without this, exports Codex auth snapshots.\n");
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
        .alias => {
            try out.writeAll("  set <selector> <alias>\n");
            try out.writeAll("                    Set one stored account alias without remote refresh.\n");
            try out.writeAll("  clear <selector>\n");
            try out.writeAll("                    Remove one stored account alias without remote refresh.\n");
        },
        .config => {
            try out.writeAll("  live --interval <seconds>\n");
            try out.writeAll("                    Set the live TUI refresh interval from 5 to 3600 seconds.\n");
        },
        .app => {
            try out.writeAll("  --id <id>          Windows package/AUMID or macOS bundle identifier.\n");
            try out.writeAll("  --codex-cli-path <path>\n");
            try out.writeAll("                     Value injected or persisted as CODEX_CLI_PATH. Defaults to latest managed Loongphy/codext.\n");
            try out.writeAll("  --codex-home <path>\n");
            try out.writeAll("                     Value injected as CODEX_HOME for this launch.\n");
            try out.writeAll("  --platform win|wsl|mac\n");
            try out.writeAll("                     Preselect the app platform. Defaults to the current app setting on Windows and mac on macOS.\n");
            try out.writeAll("  --std              Resolve the app package executable, then attach stdout/stderr to this terminal.\n");
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
            try out.writeAll("  codex-auth switch --live\n");
        },
        .list => {
            try out.writeAll("  codex-auth list\n");
            try out.writeAll("  codex-auth list --active\n");
            try out.writeAll("  codex-auth list --live\n");
            try out.writeAll("  codex-auth list --api\n");
            try out.writeAll("  codex-auth list --skip-api\n");
        },
        .login => {
            try out.writeAll("  codex-auth login\n");
            try out.writeAll("  codex-auth login --device-auth\n");
        },
        .import_auth => {
            try out.writeAll("  codex-auth import /path/to/auth.json --alias personal\n");
            try out.writeAll("  codex-auth import --cpa /path/to/token.json --alias work\n");
            try out.writeAll("  codex-auth import --purge\n");
        },
        .export_auth => {
            try out.writeAll("  codex-auth export\n");
            try out.writeAll("  codex-auth export /path/to/backup\n");
            try out.writeAll("  codex-auth export --cpa /path/to/cpa-backup\n");
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
        .alias => {
            try out.writeAll("  codex-auth alias set 02 work\n");
            try out.writeAll("  codex-auth alias set john@example.com personal\n");
            try out.writeAll("  codex-auth alias set old-name new-name\n");
            try out.writeAll("  codex-auth alias clear work\n");
        },
        .clean => {
            try out.writeAll("  codex-auth clean\n");
            try out.writeAll("  codex-auth clean background\n");
        },
        .config => {
            try out.writeAll("  codex-auth config live --interval 60\n");
        },
        .app => {
            try out.writeAll("  codex-auth app\n");
            try out.writeAll("  codex-auth app --platform win\n");
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
        .alias => {
            try out.writeAll("  Alias targets can be aliases, emails, display numbers, or partial queries.\n");
            try out.writeAll("  New aliases cannot be empty or only digits.\n");
        },
        else => {},
    }
}

fn writeSectionTitle(out: *std.Io.Writer, use_color: bool, title: []const u8) !void {
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll(title);
    if (use_color) try out.writeAll(style.ansi.reset);
}
