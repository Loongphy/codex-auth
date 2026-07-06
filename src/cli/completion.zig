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
        .bash => try writeBashCompletion(out),
        .zsh => try writeZshCompletion(out),
        .fish => try writeFishCompletion(out),
    }
}

fn writeBashCompletion(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\_codex_auth_switch_queries() {
        \\    codex-auth completion query switch 2>/dev/null
        \\}
        \\
        \\_codex_auth_complete() {
        \\    local cur prev cword
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev=""
        \\    if (( COMP_CWORD > 0 )); then
        \\        prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    fi
        \\    cword=$COMP_CWORD
        \\
        \\    local commands="- help list login import export switch remove alias clean completion config app"
        \\    local global_flags="--help -h --version -V"
        \\
        \\    if (( cword == 1 )); then
        \\        COMPREPLY=( $(compgen -W "$commands $global_flags" -- "$cur") )
        \\        return
        \\    fi
        \\
        \\    case "${COMP_WORDS[1]}" in
        \\        help)
        \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        \\            ;;
        \\        list)
        \\            COMPREPLY=( $(compgen -W "--live --active --api --skip-api" -- "$cur") )
        \\            ;;
        \\        login)
        \\            COMPREPLY=( $(compgen -W "--device-auth" -- "$cur") )
        \\            ;;
        \\        import)
        \\            if [[ "$prev" == "--alias" ]]; then
        \\                return
        \\            fi
        \\            COMPREPLY=( $(compgen -W "--alias --cpa --purge" -- "$cur") )
        \\            ;;
        \\        export)
        \\            COMPREPLY=( $(compgen -W "--cpa" -- "$cur") )
        \\            ;;
        \\        switch)
        \\            local _sw_targets
        \\            _sw_targets="$(_codex_auth_switch_queries)"
        \\            COMPREPLY=( $(compgen -W "- --live --api --skip-api $(printf '%s\n' "$_sw_targets" | awk -F '\t' '{ if ($2 != "") print $1":"$2; else print $1 }') $(printf '%s\n' "$_sw_targets" | cut -f2)" -- "$cur") )
        \\            ;;
        \\        remove)
        \\            COMPREPLY=( $(compgen -W "--live --api --skip-api --all" -- "$cur") )
        \\            ;;
        \\        alias)
        \\            if (( cword == 2 )); then
        \\                COMPREPLY=( $(compgen -W "set clear" -- "$cur") )
        \\            fi
        \\            ;;
        \\        clean)
        \\            COMPREPLY=( $(compgen -W "background" -- "$cur") )
        \\            ;;
        \\        completion)
        \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
        \\            ;;
        \\        config)
        \\            if (( cword == 2 )); then
        \\                COMPREPLY=( $(compgen -W "live" -- "$cur") )
        \\            else
        \\                COMPREPLY=( $(compgen -W "--interval" -- "$cur") )
        \\            fi
        \\            ;;
        \\        app)
        \\            COMPREPLY=( $(compgen -W "--id --codex-cli-path --codex-home --platform --std" -- "$cur") )
        \\            ;;
        \\    esac
        \\}
        \\
        \\complete -F _codex_auth_complete codex-auth
    );
}

fn writeZshCompletion(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\#compdef codex-auth
        \\
        \\_codex_auth_switch_queries() {
        \\  local value description
        \\  local -a values descriptions
        \\  while IFS=$'\t' read -r value description; do
        \\    [[ -z "$value" ]] && continue
        \\    values+=("$value")
        \\    descriptions+=("${description:-switch target}")
        \\  done <<< "$(codex-auth completion query switch 2>/dev/null)"
        \\  (( ${#values[@]} == 0 )) && return 1
        \\  compadd -Q -d descriptions -- "${values[@]}"
        \\}
        \\
        \\_codex-auth() {
        \\  local context state line
        \\  if (( CURRENT >= 3 )) && [[ "$words[2]" == "switch" ]]; then
        \\    if [[ "$PREFIX" == -* ]]; then
        \\      _values 'flag' '--live[Open the live switch UI]' '--api[Load usage and account data from APIs]' '--skip-api[Load usage and account data from local data only]'
        \\    else
        \\      _codex_auth_switch_queries || _message 'no switch targets'
        \\    fi
        \\    return
        \\  fi
        \\
        \\  _arguments -C \
        \\    '(-h --help)'{-h,--help}'[Show help]' \
        \\    '(-V --version)'{-V,--version}'[Show version]' \
        \\    '1:command:->command' \
        \\    '*::arg:->args'
        \\
        \\  case $state in
        \\    command)
        \\      _values 'command' \
        \\        '-[Switch to the previous active account]' \
        \\        'help[Show command-specific help]' \
        \\        'list[List available accounts]' \
        \\        'login[Login and add the current account]' \
        \\        'import[Import auth files or rebuild the registry]' \
        \\        'export[Export stored account auth files]' \
        \\        'switch[Switch the active account]' \
        \\        'remove[Remove one or more accounts]' \
        \\        'alias[Set or clear account aliases]' \
        \\        'clean[Delete backup and stale files under accounts/]' \
        \\        'completion[Generate shell completion scripts]' \
        \\        'config[Manage configuration]' \
        \\        'app[Launch Codex App with CLI overrides]'
        \\      ;;
        \\    args)
        \\      case $words[2] in
        \\        help)
        \\          _values 'command' - help list login import export switch remove alias clean completion config app
        \\          ;;
        \\        list)
        \\          _values 'flag' '--live[Open a live-updating table]' '--active[Refresh only the active account before rendering]' '--api[Load usage and account data from APIs]' '--skip-api[Load usage and account data from local data only]'
        \\          ;;
        \\        login)
        \\          _values 'flag' '--device-auth[Run codex login with device auth]'
        \\          ;;
        \\        import)
        \\          _values 'flag' '--alias[Set an alias for a single imported account]' '--cpa[Import CPA flat token JSON]' '--purge[Rebuild registry.json from auth files]'
        \\          ;;
        \\        export)
        \\          _values 'flag' '--cpa[Export CPA flat token JSON]'
        \\          ;;
        \\        switch)
        \\          _values 'target' '-[Switch to the previous active account]' '--live[Open the live switch UI]' '--api[Load usage and account data from APIs]' '--skip-api[Load usage and account data from local data only]'
        \\          ;;
        \\        remove)
        \\          _values 'flag' '--live[Open the live remove UI]' '--api[Load usage and account data from APIs]' '--skip-api[Load usage and account data from local data only]' '--all[Remove every stored account]'
        \\          ;;
        \\        alias)
        \\          if (( CURRENT == 3 )); then
        \\            _values 'action' set clear
        \\          fi
        \\          ;;
        \\        clean)
        \\          _values 'target' background
        \\          ;;
        \\        completion)
        \\          _values 'shell' bash zsh fish
        \\          ;;
        \\        config)
        \\          if (( CURRENT == 3 )); then
        \\            _values 'section' live
        \\          else
        \\            _values 'flag' '--interval[Set the live refresh interval in seconds]'
        \\          fi
        \\          ;;
        \\        app)
        \\          _values 'flag' '--id[Set the Windows package/AUMID or macOS bundle identifier]' '--codex-cli-path[Set CODEX_CLI_PATH for the app launch]' '--codex-home[Set CODEX_HOME for the app launch]' '--platform[Set app platform]' '--std[Attach stdout and stderr to this terminal]'
        \\          ;;
        \\      esac
        \\      ;;
        \\  esac
        \\}
        \\
        \\compdef _codex-auth codex-auth
    );
}

fn writeFishCompletion(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\function __fish_codex_auth_switch_queries
        \\    codex-auth completion query switch 2>/dev/null
        \\end
        \\
        \\function __fish_codex_auth_needs_command
        \\    not __fish_seen_subcommand_from - help list login import export switch remove alias clean completion config app
        \\end
        \\
        \\function __fish_codex_auth_using_command
        \\    __fish_seen_subcommand_from $argv
        \\end
        \\
    );

    try out.writeAll("complete -c codex-auth -e\n");
    try out.writeAll("complete -c codex-auth -f\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -l help -s h -d 'Show help'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -l version -s V -d 'Show version'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a '-' -d 'Switch to the previous active account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a help -d 'Show command-specific help'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a list -d 'List available accounts'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a login -d 'Login and add the current account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a import -d 'Import auth files or rebuild the registry'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a export -d 'Export stored account auth files'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a switch -d 'Switch the active account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a remove -d 'Remove one or more accounts'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a alias -d 'Set or clear account aliases'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a clean -d 'Delete backup and stale files under accounts/'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a completion -d 'Generate shell completion scripts'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a config -d 'Manage configuration'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_needs_command' -a app -d 'Launch Codex App with CLI overrides'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command help' -a '- list login import export switch remove alias clean completion config app'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command list' -l live -d 'Open a live-updating table'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command list' -l active -d 'Refresh only the active account before rendering'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command list' -l api -d 'Load usage and account data from APIs'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command list' -l skip-api -d 'Load usage and account data from local data only'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command login' -l device-auth -d 'Run codex login with device auth'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command import' -l alias -r -d 'Set an alias for a single imported account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command import' -l cpa -d 'Import CPA flat token JSON'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command import' -l purge -d 'Rebuild registry.json from auth files'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command import' -f -a '(__fish_complete_path)' -d 'Auth file or directory'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command export' -l cpa -d 'Export CPA flat token JSON'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command export' -f -a '(__fish_complete_path)' -d 'Export directory'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command switch' -l live -d 'Open the live switch UI'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command switch' -l api -d 'Load usage and account data from APIs'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command switch' -l skip-api -d 'Load usage and account data from local data only'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command switch' -a '-' -d 'Switch to the previous active account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command switch' -a '(__fish_codex_auth_switch_queries)' -d 'Switch target'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command remove' -l live -d 'Open the live remove UI'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command remove' -l api -d 'Load usage and account data from APIs'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command remove' -l skip-api -d 'Load usage and account data from local data only'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command remove' -l all -d 'Remove every stored account'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command alias' -a set -d 'Set one stored account alias'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command alias' -a clear -d 'Clear one stored account alias'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command clean' -a background -d 'Delete stale background files'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command completion' -a 'bash zsh fish' -d 'Generate shell completions'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command config' -a live -d 'Manage live refresh settings'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_seen_subcommand_from config; and __fish_seen_subcommand_from live' -l interval -r -d 'Set the live refresh interval in seconds'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command app' -l id -r -d 'Set the app identifier'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command app' -l codex-cli-path -r -d 'Set CODEX_CLI_PATH'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command app' -l codex-home -r -d 'Set CODEX_HOME'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command app' -l platform -r -a 'win wsl mac' -d 'Set app platform'\n");
    try out.writeAll("complete -c codex-auth -n '__fish_codex_auth_using_command app' -l std -d 'Attach stdout and stderr to this terminal'\n");
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
