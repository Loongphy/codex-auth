const std = @import("std");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const io_util = @import("../core/io_util.zig");
const version = @import("../version.zig");
const types = @import("types.zig");
const help = @import("help.zig");
const style = @import("style.zig");
const io = @import("io.zig");

const UsageError = types.UsageError;

fn importReportStyle(outcome: registry.ImportOutcome) []const u8 {
    return switch (outcome) {
        .imported, .updated => style.ansi.green,
        .skipped => style.ansi.red,
    };
}

fn importOutcomeLabel(outcome: registry.ImportOutcome) []const u8 {
    return switch (outcome) {
        .imported => "imported",
        .updated => "updated",
        .skipped => "skipped",
    };
}

pub fn printUsageError(usage_err: *const UsageError) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" {s}\n\n", .{usage_err.message});
    try help.writeUsageSection(out, usage_err.topic);
    try out.writeAll("\n");
    try writeHintPrefixTo(out, use_color);
    try out.print(" Run `{s}` for help and examples.\n", .{help.helpCommandForTopic(usage_err.topic)});
    try out.flush();
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
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    try writeImportReportWithColor(stdout.out(), stderr.out(), report, stdout.color_enabled, stderr.color_enabled);
}

pub fn writeImportReport(
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    report: *const registry.ImportReport,
) !void {
    try writeImportReportWithColor(out, err_out, report, false, false);
}

pub fn writeImportReportWithColor(
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    report: *const registry.ImportReport,
    stdout_color: bool,
    stderr_color: bool,
) !void {
    if (report.render_kind == .scanned) {
        try out.print("Scanning {s}...\n", .{report.source_label.?});
        try out.flush();
    }

    var current_item_label: ?[]const u8 = null;
    for (report.events.items) |event| {
        if (event.item_index) |item_index| {
            if (current_item_label == null or !std.mem.eql(u8, current_item_label.?, event.label)) {
                if (stdout_color) try out.writeAll(style.ansi.cyan);
                try out.print("{s}:\n", .{event.label});
                if (stdout_color) try out.writeAll(style.ansi.reset);
                try out.flush();
                current_item_label = event.label;
            }
            // Array item reports stay on stdout as one contiguous human-readable
            // block. Splitting skipped items to stderr can reorder the file
            // header and item rows when callers merge the two streams.
            const item_out = out;
            const item_color = stdout_color;
            if (item_color) try item_out.writeAll(importReportStyle(event.outcome));
            try item_out.print("  [{d}] {s}", .{ item_index, importOutcomeLabel(event.outcome) });
            if (event.outcome == .skipped) {
                try item_out.print("   {s}", .{event.reason.?});
            } else if (event.detail) |detail| {
                try item_out.print("  {s}", .{detail});
            }
            try item_out.writeAll("\n");
            if (item_color) try item_out.writeAll(style.ansi.reset);
            try item_out.flush();
            continue;
        }

        current_item_label = null;
        switch (event.outcome) {
            .imported, .updated => {
                if (stdout_color) try out.writeAll(importReportStyle(event.outcome));
                switch (event.outcome) {
                    .imported => try out.print("  imported  {s}\n", .{event.label}),
                    .updated => try out.print("  updated   {s}\n", .{event.label}),
                    .skipped => unreachable,
                }
                if (stdout_color) try out.writeAll(style.ansi.reset);
                try out.flush();
            },
            .skipped => {
                if (stderr_color) try err_out.writeAll(importReportStyle(.skipped));
                try err_out.print("  skipped   {s}: {s}\n", .{ event.label, event.reason.? });
                if (stderr_color) try err_out.writeAll(style.ansi.reset);
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

pub fn writeErrorPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(style.ansi.red);
    try out.writeAll("error:");
    if (use_color) try out.writeAll(style.ansi.reset);
}

pub fn writeHintPrefixTo(out: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try out.writeAll(style.ansi.cyan);
    try out.writeAll("hint:");
    if (use_color) try out.writeAll(style.ansi.reset);
}

pub fn printAccountNotFoundError(query: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no account matches '{s}'.\n", .{query});
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Remove accepts one or more aliases, emails, display numbers, or partial queries.\n");
    try out.flush();
}

pub fn printSwitchAccountNotFoundError(query: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no switch target matches '{s}'.\n", .{query});
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Switch accepts one target: alias, email, display number, or partial query.\n");
    try out.flush();
}

pub fn printAliasAccountNotFoundError(query: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no alias target matches '{s}'.\n", .{query});
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Alias targets accept one account: alias, email, display number, or partial query.\n");
    try out.flush();
}

pub fn printAccountNotFoundErrors(queries: []const []const u8) !void {
    if (queries.len == 0) return;
    if (queries.len == 1) {
        return printAccountNotFoundError(queries[0]);
    }

    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" no account matches: ");
    for (queries, 0..) |query, idx| {
        if (idx != 0) try out.writeAll(", ");
        try out.writeAll(query);
    }
    try out.writeAll(".\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Remove accepts one or more aliases, emails, display numbers, or partial queries.\n");
    try out.flush();
}

pub fn printSwitchRequiresTtyError() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive switch requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth switch` in a terminal, or narrow `codex-auth switch <alias|email|display-number|query>` to one account.\n");
    try out.flush();
}

pub fn printListRequiresTtyError() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" live list requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth list --live` in a terminal.\n");
    try out.flush();
}

pub fn printRemoveRequiresTtyError() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive remove requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use `codex-auth remove <alias|email|display-number|query>...` or `codex-auth remove --all` instead.\n");
    try out.flush();
}

pub fn printAliasRequiresTtyError() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" multiple alias targets require a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Narrow the selector or use a displayed row number.\n");
    try out.flush();
}

pub fn printInvalidAliasError(reason: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" invalid alias: {s}\n", .{reason});
    try out.flush();
}

pub fn printDuplicateAliasError(alias_value: []const u8, email: []const u8) !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
    try writeErrorPrefixTo(out, use_color);
    try out.print(" alias '{s}' is already used by {s}.\n", .{ alias_value, email });
    try out.flush();
}

pub fn printAliasSet(rec: *const registry.AccountRecord, old_alias: []const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (old_alias.len == 0) {
        try out.print("Set alias for {s}: {s}\n", .{ rec.email, rec.alias });
    } else if (std.mem.eql(u8, old_alias, rec.alias)) {
        try out.print("Alias already set for {s}: {s}\n", .{ rec.email, rec.alias });
    } else {
        try out.print("Updated alias for {s}: {s} -> {s}\n", .{ rec.email, old_alias, rec.alias });
    }
    try out.flush();
}

pub fn printAliasCleared(rec: *const registry.AccountRecord, old_alias: []const u8) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    if (old_alias.len == 0) {
        try out.print("Alias already empty for {s}.\n", .{rec.email});
    } else {
        try out.print("Cleared alias for {s}: {s}\n", .{ rec.email, old_alias });
    }
    try out.flush();
}

pub fn printInvalidRemoveSelectionError() !void {
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
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

        const label = if (row.depth == 0 or current_header == null) blk: {
            const rec = &reg.accounts.items[row.account_index.?];
            break :blk try display_rows.buildAccountIdentityLabelAlloc(allocator, rec);
        } else try std.fmt.allocPrint(allocator, "{s} / {s}", .{ current_header.?, row.account_cell });
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
    var stderr: io_util.Stderr = undefined;
    stderr.init();
    const out = stderr.out();
    const use_color = stderr.color_enabled;
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
    const n = try io.readFileOnce(std.Io.File.stdin(), &buf);
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

pub fn printSwitchedAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
) !void {
    const label = if (registry.findAccountIndexByAccountKey(reg, account_key)) |idx|
        try display_rows.buildAccountIdentityLabelAlloc(allocator, &reg.accounts.items[idx])
    else
        try allocator.dupe(u8, account_key);
    defer allocator.free(label);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = stdout.color_enabled;
    if (use_color) try out.writeAll(style.ansi.green);
    try out.print("Switched to {s}\n", .{label});
    if (use_color) try out.writeAll(style.ansi.reset);
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
