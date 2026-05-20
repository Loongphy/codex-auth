const std = @import("std");
const io_util = @import("../core/io_util.zig");
const types = @import("types.zig");
const registry = @import("../registry/root.zig");
const display_rows = @import("../tui/display.zig");

pub fn printCompletion(shell: types.CompletionShell) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCompletion(out, shell);
    try out.flush();
}

pub fn printQueryCompletion(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    target: types.CompletionQueryTarget,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    switch (target) {
        .switch_account => try writeSwitchQueryCompletion(out, allocator, codex_home),
    }
    try out.flush();
}

pub fn writeCompletion(out: *std.Io.Writer, shell: types.CompletionShell) !void {
    switch (shell) {
        .fish => try writeFishCompletion(out),
    }
}

fn writeFishCompletion(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\function __fish_codex_auth_switch_queries
        \\    $argv[1] completion query switch 2>/dev/null
        \\end
        \\
        \\function __fish_codex_auth_needs_command
        \\    not __fish_seen_subcommand_from help list login import export switch remove alias clean completion config
        \\end
        \\
        \\function __fish_codex_auth_using_command
        \\    __fish_seen_subcommand_from $argv
        \\end
        \\
    );

    try writeFishCommandCompletion(out, "codex-auth");
    try out.writeAll("\n");
    try writeFishCommandCompletion(out, "cx");
}

fn writeFishCommandCompletion(out: *std.Io.Writer, command_name: []const u8) !void {
    try out.print("complete -c {s} -e\n", .{command_name});
    try out.print("complete -c {s} -f\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -l help -s h -d 'Show help'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -l version -s V -d 'Show version'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a help -d 'Show command-specific help'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a list -d 'List available accounts'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a login -d 'Login and add the current account'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a import -d 'Import auth files or rebuild the registry'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a export -d 'Export stored account auth files'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a switch -d 'Switch the active account'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a remove -d 'Remove one or more accounts'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a alias -d 'Set or clear account aliases'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a clean -d 'Delete backup and stale files under accounts/'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a completion -d 'Generate shell completion scripts'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_needs_command' -a config -d 'Manage configuration'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command help' -a 'list login import export switch remove alias clean completion config'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command list' -l live -d 'Open a live-updating table'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command list' -l active -d 'Refresh only the active account before rendering'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command list' -l api -d 'Load usage and account data from APIs'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command list' -l skip-api -d 'Load usage and account data from local data only'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command login' -l device-auth -d 'Run codex login with device auth'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command import' -l alias -r -d 'Set an alias for a single imported account'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command import' -l cpa -d 'Import CPA flat token JSON'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command import' -l purge -d 'Rebuild registry.json from auth files'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command import' -f -a '(__fish_complete_path)' -d 'Auth file or directory'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command export' -l cpa -d 'Export CPA flat token JSON'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command export' -f -a '(__fish_complete_path)' -d 'Export directory'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command switch' -l live -d 'Open the live switch UI'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command switch' -l api -d 'Load usage and account data from APIs'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command switch' -l skip-api -d 'Load usage and account data from local data only'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command switch' -a '(__fish_codex_auth_switch_queries {s})' -d 'Switch target'\n", .{ command_name, command_name });
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command remove' -l live -d 'Open the live remove UI'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command remove' -l api -d 'Load usage and account data from APIs'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command remove' -l skip-api -d 'Load usage and account data from local data only'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command remove' -l all -d 'Remove every stored account'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command alias' -a set -d 'Set one stored account alias'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command alias' -a clear -d 'Clear one stored account alias'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command clean' -a background -d 'Delete stale background files'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command completion' -a fish -d 'Generate Fish shell completions'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_codex_auth_using_command config' -a live -d 'Manage live refresh settings'\n", .{command_name});
    try out.print("complete -c {s} -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from live' -l interval -r -d 'Set the live refresh interval in seconds'\n", .{command_name});
}

fn writeSwitchQueryCompletion(out: *std.Io.Writer, allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = registry.loadRegistry(allocator, codex_home) catch return;
    defer reg.deinit(allocator);

    var display = display_rows.buildDisplayRows(allocator, &reg, null) catch return;
    defer display.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iter = seen.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (display.selectable_row_indices, 0..) |row_idx, displayed_idx| {
        const account_idx = display.rows[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];

        var number_buf: [16]u8 = undefined;
        const display_number = std.fmt.bufPrint(&number_buf, "{d:0>2}", .{displayed_idx + 1}) catch unreachable;
        try writeUniqueCandidate(out, &seen, display_number, rec.email, allocator);
    }
}

fn writeUniqueCandidate(
    out: *std.Io.Writer,
    seen: *std.StringHashMap(void),
    value: []const u8,
    description: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (value.len == 0) return;
    const entry = try seen.getOrPut(value);
    if (entry.found_existing) return;
    entry.key_ptr.* = try allocator.dupe(u8, value);
    try out.print("{s}\t{s}\n", .{ value, description });
}
