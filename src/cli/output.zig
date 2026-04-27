const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const builtin = @import("builtin");
const display_rows = @import("../tui/display.zig");
const registry = @import("../registry/root.zig");
const io_util = @import("../core/io_util.zig");
const version = @import("../version.zig");
const types = @import("types.zig");
const help = @import("help.zig");
const style = @import("style.zig");
const io = @import("io.zig");

const UsageError = types.UsageError;

pub fn importReportMarker(outcome: registry.ImportOutcome, is_windows: bool) []const u8 {
    return switch (outcome) {
        .imported => if (is_windows) "[+]" else "✓",
        .updated => if (is_windows) "[~]" else "✓",
        .skipped => if (is_windows) "[x]" else "✗",
    };
}

pub fn printUsageError(usage_err: *const UsageError) !void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
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
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(app_runtime.io(), &stderr_buffer);
    try writeImportReport(stdout.out(), &stderr_writer.interface, report);
}

pub fn writeImportReport(
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    report: *const registry.ImportReport,
) !void {
    const is_windows = builtin.os.tag == .windows;
    if (report.render_kind == .scanned) {
        try out.print("Scanning {s}...\n", .{report.source_label.?});
        try out.flush();
    }

    for (report.events.items) |event| {
        switch (event.outcome) {
            .imported => {
                try out.print("  {s} imported  {s}\n", .{ importReportMarker(.imported, is_windows), event.label });
                try out.flush();
            },
            .updated => {
                try out.print("  {s} updated   {s}\n", .{ importReportMarker(.updated, is_windows), event.label });
                try out.flush();
            },
            .skipped => {
                try err_out.print("  {s} skipped   {s}: {s}\n", .{ importReportMarker(.skipped, is_windows), event.label, event.reason.? });
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
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no account matches '{s}'.\n", .{query});
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Remove accepts one or more aliases, emails, display numbers, or partial queries.\n");
    try out.flush();
}

pub fn printSwitchAccountNotFoundError(query: []const u8) !void {
    var buffer: [768]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.print(" no switch target matches '{s}'.\n", .{query});
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Switch accepts one target: alias, email, display number, or partial query.\n");
    try out.flush();
}

pub fn printAccountNotFoundErrors(queries: []const []const u8) !void {
    if (queries.len == 0) return;
    if (queries.len == 1) {
        return printAccountNotFoundError(queries[0]);
    }

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
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
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive switch requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth switch` in a terminal, or narrow `codex-auth switch <alias|email|display-number|query>` to one account.\n");
    try out.flush();
}

pub fn printListRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" live list requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Run `codex-auth list --live` in a terminal.\n");
    try out.flush();
}

pub fn printRemoveRequiresTtyError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
    try writeErrorPrefixTo(out, use_color);
    try out.writeAll(" interactive remove requires a TTY.\n");
    try writeHintPrefixTo(out, use_color);
    try out.writeAll(" Use `codex-auth remove <alias|email|display-number|query>...` or `codex-auth remove --all` instead.\n");
    try out.flush();
}

pub fn printInvalidRemoveSelectionError() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
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
            if (std.mem.eql(u8, row.account_cell, rec.email)) {
                const preferred = try display_rows.buildPreferredAccountLabelAlloc(allocator, rec, rec.email);
                defer allocator.free(preferred);
                if (std.mem.eql(u8, preferred, rec.email)) {
                    break :blk try allocator.dupe(u8, row.account_cell);
                }
                break :blk try std.fmt.allocPrint(allocator, "{s} / {s}", .{ rec.email, preferred });
            }
            break :blk try std.fmt.allocPrint(allocator, "{s} / {s}", .{ rec.email, row.account_cell });
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
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
    const out = &writer.interface;
    const use_color = style.stderrColorEnabled();
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
        try display_rows.buildPreferredAccountLabelAlloc(allocator, &reg.accounts.items[idx], reg.accounts.items[idx].email)
    else
        try allocator.dupe(u8, account_key);
    defer allocator.free(label);

    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    const use_color = style.stdoutColorEnabled();
    if (use_color) try out.writeAll(style.ansi.green);
    try out.print("Switched to {s}\n", .{label});
    if (use_color) try out.writeAll(style.ansi.reset);
    try out.flush();
}

fn writeCodexLoginLaunchFailureHint(err_name: []const u8, use_color: bool) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(app_runtime.io(), &buffer);
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
