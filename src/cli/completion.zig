const std = @import("std");
const io_util = @import("../core/io_util.zig");
const types = @import("types.zig");
const registry = @import("../registry/root.zig");
const display_rows = @import("../tui/display.zig");
const query = @import("../workflows/query.zig");

pub fn printCompletion(shell: types.CompletionShell) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCompletion(out, shell);
    try out.flush();
}

pub fn printCompleteResponse(
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    args: []const []const u8,
    descriptions: bool,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCompleteResponse(out, allocator, codex_home, args, descriptions);
    try out.flush();
}

pub fn writeCompletion(out: *std.Io.Writer, shell: types.CompletionShell) !void {
    switch (shell) {
        .bash => try out.writeAll(bash_script),
        .zsh => try out.writeAll(zsh_script),
        .fish => try out.writeAll(fish_script),
        .pwsh => try out.writeAll(pwsh_script),
    }
}

const bash_script =
    \\_codex_auth_complete() {
    \\    COMPREPLY=()
    \\    local i w buf="" cur tail before directive=0 value desc out join_next=0 dpath dpre btail dkeep cand
    \\    local -a argv cands
    \\    for (( i=1; i<=COMP_CWORD; i++ )); do
    \\        w="${COMP_WORDS[i]}"
    \\        if [[ "$w" == ":" || "$w" == "=" ]]; then
    \\            buf+="$w"
    \\            join_next=1
    \\            continue
    \\        fi
    \\        if (( join_next )); then
    \\            buf+="$w"
    \\            join_next=0
    \\            continue
    \\        fi
    \\        (( i > 1 )) && argv+=("$buf")
    \\        buf="$w"
    \\    done
    \\    argv+=("$buf")
    \\    out="$(codex-auth __completeNoDesc "${argv[@]}" 2>/dev/null)"
    \\    while IFS=$'\t' read -r value desc; do
    \\        case "$value" in
    \\            :*) directive="${value#:}" ;;
    \\            "") ;;
    \\            *)  cands+=("$value") ;;
    \\        esac
    \\    done <<< "$out"
    \\    (( directive == 1 )) && return
    \\    cur="${argv[$((${#argv[@]} - 1))]}"
    \\    tail="$cur"
    \\    [[ "$COMP_WORDBREAKS" == *":"* ]] && tail="${tail##*:}"
    \\    [[ "$COMP_WORDBREAKS" == *"="* ]] && tail="${tail##*=}"
    \\    before="${cur%"$tail"}"
    \\    if (( directive & 16 )); then
    \\        dpath="$cur" dpre=""
    \\        if [[ "$dpath" == --*=* ]]; then
    \\            [[ "$COMP_WORDBREAKS" == *"="* ]] || dpre="${dpath%%=*}="
    \\            dpath="${dpath#*=}"
    \\        fi
    \\        btail="$dpath"
    \\        [[ "$COMP_WORDBREAKS" == *":"* ]] && btail="${btail##*:}"
    \\        [[ "$COMP_WORDBREAKS" == *"="* ]] && btail="${btail##*=}"
    \\        dkeep="${dpath%"$btail"}"
    \\        while IFS= read -r cand; do
    \\            COMPREPLY+=("${dpre}${cand#"$dkeep"}")
    \\        done < <(compgen -d -- "$dpath")
    \\        compopt -o filenames 2>/dev/null
    \\    elif (( ${#cands[@]} )); then
    \\        for cand in "${cands[@]}"; do
    \\            if [[ "$cand" == "$cur"* ]]; then
    \\                printf -v cand '%q' "${cand#"$before"}"
    \\                COMPREPLY+=("$cand")
    \\            fi
    \\        done
    \\    fi
    \\    (( directive & 2 )) && compopt -o nospace 2>/dev/null
    \\    (( directive & 32 )) && compopt -o nosort 2>/dev/null
    \\    (( directive & 4 )) || compopt -o default 2>/dev/null
    \\    return
    \\}
    \\
    \\complete -F _codex_auth_complete codex-auth
;

const zsh_script =
    \\#compdef codex-auth
    \\
    \\_codex-auth() {
    \\  local out value desc esc
    \\  local -a argv pairs
    \\  local directive=0
    \\  argv=("${(@)words[2,CURRENT]}")
    \\  out="$(codex-auth __complete "${argv[@]}" 2>/dev/null)"
    \\  while IFS=$'\t' read -r value desc; do
    \\    case "$value" in
    \\      (:*) directive="${value#:}" ;;
    \\      ("") ;;
    \\      (*)  esc="${value//\\/\\\\}"
    \\           esc="${esc//:/\\:}"
    \\           [[ $desc == "$value" ]] && desc=
    \\           pairs+=("${esc}${desc:+:$desc}") ;;
    \\    esac
    \\  done <<< "$out"
    \\  (( directive == 1 )) && return 1
    \\  if (( directive & 16 )); then
    \\    compset -P '*='
    \\    _files -/
    \\    return
    \\  fi
    \\  if (( ${#pairs[@]} > 0 )); then
    \\    if (( directive & 32 )); then
    \\      _describe -V "command" pairs
    \\    else
    \\      _describe "command" pairs
    \\    fi
    \\  fi
    \\  (( directive & 4 )) || { compset -P '*='; _files; }
    \\}
    \\
    \\compdef _codex-auth codex-auth
;

const fish_script =
    \\function __fish_codex_auth_complete
    \\    set -l tokens (commandline -opc)
    \\    if test (count $tokens) -gt 0
    \\        set -e tokens[1]
    \\    end
    \\    set -l cur (commandline -ct)
    \\    set -a tokens "$cur"
    \\    set -l directive 0
    \\    for line in (codex-auth __complete $tokens 2>/dev/null)
    \\        if string match -q ':*' -- $line
    \\            set directive (string sub -s 2 -- $line)
    \\        else
    \\            echo -- $line
    \\        end
    \\    end
    \\    test "$directive" = "1"; and return
    \\    set -l dirs (math -s0 "floor($directive / 16) % 2" 2>/dev/null)
    \\    if test "$dirs" = "1"
    \\        __fish_complete_directories
    \\        return
    \\    end
    \\    set -l nofile (math -s0 "floor($directive / 4) % 2" 2>/dev/null)
    \\    if test "$nofile" != "1"
    \\        __fish_complete_path
    \\    end
    \\end
    \\
    \\complete -c codex-auth -e
    \\complete -c codex-auth -f -a '(__fish_codex_auth_complete)'
;

const pwsh_script =
    \\function __codex_auth_complete {
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    $words = @($commandAst.CommandElements | Select-Object -Skip 1 | Where-Object { $_.Extent.StartOffset -lt $cursorPosition } | ForEach-Object { $_.ToString() })
    \\    if ($wordToComplete.Length -gt 0 -and $words.Count -gt 0 -and $words[-1] -eq $wordToComplete) {
    \\        $words = @($words | Select-Object -First ($words.Count - 1))
    \\    }
    \\    $words += $wordToComplete
    \\    if ($wordToComplete.Length -eq 0 -and
    \\        ($PSVersionTable.PsVersion -lt [version]'7.2.0' -or
    \\         ($PSVersionTable.PsVersion -lt [version]'7.3.0' -and -not [ExperimentalFeature]::IsEnabled("PSNativeCommandArgumentPassing")) -or
    \\         (($PSVersionTable.PsVersion -ge [version]'7.3.0' -or [ExperimentalFeature]::IsEnabled("PSNativeCommandArgumentPassing")) -and
    \\          $PSNativeCommandArgumentPassing -eq 'Legacy'))) {
    \\        $words[-1] = '""'
    \\    }
    \\    $quote = {
    \\        param($text)
    \\        if ($text -match '[\s''"`$;|&<>(){}\[\],#*?~^!]') {
    \\            return "'" + ($text -replace "'", "''") + "'"
    \\        }
    \\        return $text
    \\    }
    \\    $directive = 0
    \\    $results = [System.Collections.Generic.List[System.Management.Automation.CompletionResult]]::new()
    \\    foreach ($line in (codex-auth __complete @words 2>$null)) {
    \\        if ($line -match '^:(\d+)$') {
    \\            $directive = [int]$Matches[1]
    \\            continue
    \\        }
    \\        $parts = $line -split "`t", 2
    \\        $desc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
    \\        $results.Add([System.Management.Automation.CompletionResult]::new((& $quote $parts[0]), $parts[0], 'ParameterValue', $desc))
    \\    }
    \\    if ($directive -eq 1) { return }
    \\    if (($directive -band 4) -and $results.Count -eq 0) {
    \\        # An empty CompletionResult crashes PS 5.1; a single-space result
    \\        # still stops the default filename fallback.
    \\        if ($PSVersionTable.PSVersion.Major -lt 7) {
    \\            $results.Add([System.Management.Automation.CompletionResult]::new(' ', ' ', 'ParameterValue', ' '))
    \\            return $results
    \\        }
    \\        return
    \\    }
    \\    $flagPrefix = ''
    \\    $pathWord = $wordToComplete
    \\    if ($pathWord -match '^(--[^=]+=)(.*)$') { $flagPrefix = $Matches[1]; $pathWord = $Matches[2] }
    \\    $dirPart = if ($pathWord.Length -gt 0) { [System.IO.Path]::GetDirectoryName($pathWord) } else { $null }
    \\    $sep = if ($pathWord.Contains('/')) { '/' } else { [IO.Path]::DirectorySeparatorChar }
    \\    if ($directive -band 16) {
    \\        foreach ($entry in (Get-ChildItem -Name "$pathWord*" -Directory -ErrorAction SilentlyContinue)) {
    \\            $joined = if ([string]::IsNullOrEmpty($dirPart)) { $entry } elseif ($dirPart -match '[\\/]$') { "$dirPart$entry" } else { "$dirPart$sep$entry" }
    \\            $value = "$flagPrefix$joined$sep"
    \\            $results.Add([System.Management.Automation.CompletionResult]::new((& $quote $value), $value, 'ProviderContainer', $entry))
    \\        }
    \\    } elseif (-not ($directive -band 4)) {
    \\        foreach ($entry in (Get-ChildItem -Name "$pathWord*" -ErrorAction SilentlyContinue)) {
    \\            $joined = if ([string]::IsNullOrEmpty($dirPart)) { $entry } elseif ($dirPart -match '[\\/]$') { "$dirPart$entry" } else { "$dirPart$sep$entry" }
    \\            $type = if (Test-Path -LiteralPath $joined -PathType Container) { 'ProviderContainer' } else { 'ProviderItem' }
    \\            $value = "$flagPrefix$joined"
    \\            $results.Add([System.Management.Automation.CompletionResult]::new((& $quote $value), $value, $type, $entry))
    \\        }
    \\    }
    \\    return $results
    \\}
    \\
    \\if ($PSVersionTable.PSVersion.Major -ge 6) {
    \\    Register-ArgumentCompleter -Native -CommandName 'codex-auth' -ScriptBlock ${function:__codex_auth_complete}
    \\} else {
    \\    # Windows PowerShell 5.1 has no -Native completers; register on the
    \\    # command name instead, which completes through a `codex-auth` shim
    \\    # function wrapping the executable.
    \\    Register-ArgumentCompleter -CommandName 'codex-auth' -ScriptBlock ${function:__codex_auth_complete}
    \\}
;

const Directive = struct {
    pub const none: u6 = 0;
    pub const err: u6 = 1;
    pub const no_space: u6 = 2;
    pub const no_file: u6 = 4;
    pub const filter_dirs: u6 = 16;
    pub const keep_order: u6 = 32;
};
const static_directive: u6 = Directive.no_file | Directive.keep_order;

const ValueKind = enum { none, choices, freeform, path, dir };
const PosKind = enum { account, literal, freeform, path, dir, command_name };

const FlagSpec = struct {
    name: []const u8,
    desc: []const u8,
    value: ValueKind = .none,
    choices: []const []const u8 = &.{},
    // Flags the parser rejects alongside this one (checked both directions).
    conflicts: []const []const u8 = &.{},
};
const Cand = struct {
    value: []const u8,
    desc: []const u8,
};
const PosSpec = struct {
    kind: PosKind,
    literals: []const Cand = &.{},
    repeat: bool = false,
    // Flags that make any positional of this command invalid when seen.
    blocked_by: []const []const u8 = &.{},
};
const CmdSpec = struct {
    name: []const u8,
    desc: []const u8,
    flags: []const FlagSpec = &.{},
    subs: []const CmdSpec = &.{},
    positionals: []const PosSpec = &.{},
    // Flags the parser rejects once a positional selector has been typed.
    pos_blocks_flags: []const []const u8 = &.{},
    // Whether `-h`/`--help` are valid immediately after this command name.
    accepts_help: bool = true,
};

const help_flags = [_]FlagSpec{
    .{ .name = "-h", .desc = "Show help" },
    .{ .name = "--help", .desc = "Show help" },
};
const global_cands = [_]Cand{
    .{ .value = "-", .desc = "Switch to the previous active account" },
    .{ .value = "-h", .desc = "Show help" },
    .{ .value = "--help", .desc = "Show help" },
    .{ .value = "-V", .desc = "Show version" },
    .{ .value = "--version", .desc = "Show version" },
};

const list_flags = [_]FlagSpec{
    .{ .name = "--live", .desc = "Open a live-updating table", .conflicts = &.{"--json"} },
    .{ .name = "--active", .desc = "Refresh only the active account before rendering" },
    .{ .name = "--api", .desc = "Load usage and account data from APIs", .conflicts = &.{"--skip-api"} },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only", .conflicts = &.{"--api"} },
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document", .conflicts = &.{"--live"} },
};
const login_flags = [_]FlagSpec{
    .{ .name = "--device-auth", .desc = "Run codex login with device auth" },
};
const import_flags = [_]FlagSpec{
    .{ .name = "--alias", .desc = "Set an alias for a single imported account", .value = .freeform },
    .{ .name = "--cpa", .desc = "Import CPA flat token JSON", .conflicts = &.{"--purge"} },
    .{ .name = "--purge", .desc = "Rebuild registry.json from auth files", .conflicts = &.{"--cpa"} },
};
const export_flags = [_]FlagSpec{
    .{ .name = "--cpa", .desc = "Export CPA flat token JSON" },
};
const switch_flags = [_]FlagSpec{
    .{ .name = "--live", .desc = "Open the live switch UI", .conflicts = &.{"--json"} },
    .{ .name = "--api", .desc = "Load usage and account data from APIs", .conflicts = &.{ "--skip-api", "--json" } },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only", .conflicts = &.{ "--api", "--json" } },
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document for non-interactive switch" },
    .{ .name = "--no-restart-daemon", .desc = "Attempt in-place daemon reload; never restart" },
};
const remove_flags = [_]FlagSpec{
    .{ .name = "--live", .desc = "Open the live remove UI", .conflicts = &.{ "--json", "--all" } },
    .{ .name = "--api", .desc = "Load usage and account data from APIs", .conflicts = &.{ "--skip-api", "--all" } },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only", .conflicts = &.{ "--api", "--all" } },
    .{ .name = "--all", .desc = "Remove every stored account" },
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document for non-interactive remove" },
};
const app_flags = [_]FlagSpec{
    .{ .name = "--id", .desc = "Set the Windows package/AUMID or macOS bundle identifier", .value = .freeform },
    .{ .name = "--codex-cli-path", .desc = "Set CODEX_CLI_PATH for the app launch", .value = .path },
    .{ .name = "--codex-home", .desc = "Set CODEX_HOME for the app launch", .value = .dir },
    .{ .name = "--platform", .desc = "Set app platform", .value = .choices, .choices = &.{ "win", "wsl", "mac" } },
    .{ .name = "--std", .desc = "Attach stdout and stderr to this terminal" },
};
const config_live_flags = [_]FlagSpec{
    .{ .name = "--interval", .desc = "Set the live refresh interval in seconds", .value = .freeform },
};

const dash_cands = [_]Cand{.{ .value = "-", .desc = "Switch to the previous active account" }};
const dash_flags = [_]FlagSpec{
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document for non-interactive switch" },
    .{ .name = "--no-restart-daemon", .desc = "Attempt in-place daemon reload; never restart" },
};
const clean_cands = [_]Cand{.{ .value = "background", .desc = "Delete stale background files" }};
const shell_cands = [_]Cand{
    .{ .value = "bash", .desc = "Print Bash completion script" },
    .{ .value = "zsh", .desc = "Print Zsh completion script" },
    .{ .value = "fish", .desc = "Print Fish completion script" },
    .{ .value = "pwsh", .desc = "Print PowerShell completion script" },
    .{ .value = "powershell", .desc = "Print PowerShell completion script" },
};

const help_positionals = [_]PosSpec{.{ .kind = .command_name }};
const import_positionals = [_]PosSpec{.{ .kind = .path }};
const export_positionals = [_]PosSpec{.{ .kind = .path }};
const switch_positionals = [_]PosSpec{.{ .kind = .account, .blocked_by = &.{ "--live", "--api", "--skip-api" } }};
const remove_positionals = [_]PosSpec{.{ .kind = .account, .repeat = true, .blocked_by = &.{ "--live", "--api", "--skip-api", "--all" } }};
const reset_positionals = [_]PosSpec{.{ .kind = .account }};
const clean_positionals = [_]PosSpec{.{ .kind = .literal, .literals = &clean_cands }};
const completion_positionals = [_]PosSpec{.{ .kind = .literal, .literals = &shell_cands }};
const alias_set_positionals = [_]PosSpec{ .{ .kind = .account }, .{ .kind = .freeform } };
const alias_clear_positionals = [_]PosSpec{.{ .kind = .account }};

const alias_subs = [_]CmdSpec{
    .{ .name = "set", .desc = "Set one stored account alias", .positionals = &alias_set_positionals, .accepts_help = false },
    .{ .name = "clear", .desc = "Clear one stored account alias", .positionals = &alias_clear_positionals, .accepts_help = false },
};
const config_subs = [_]CmdSpec{
    .{ .name = "live", .desc = "Manage live refresh settings", .flags = &config_live_flags },
};

const command_specs = [_]CmdSpec{
    .{ .name = "help", .desc = "Show command-specific help", .positionals = &help_positionals, .accepts_help = false },
    .{ .name = "list", .desc = "List available accounts", .flags = &list_flags },
    .{ .name = "login", .desc = "Login and add the current account", .flags = &login_flags },
    .{ .name = "import", .desc = "Import auth files or rebuild the registry", .flags = &import_flags, .positionals = &import_positionals },
    .{ .name = "export", .desc = "Export stored account auth files", .flags = &export_flags, .positionals = &export_positionals },
    .{ .name = "switch", .desc = "Switch the active account", .flags = &switch_flags, .positionals = &switch_positionals, .pos_blocks_flags = &.{ "--live", "--api", "--skip-api" } },
    .{ .name = "remove", .desc = "Remove one or more accounts", .flags = &remove_flags, .positionals = &remove_positionals, .pos_blocks_flags = &.{ "--live", "--api", "--skip-api", "--all" } },
    .{ .name = "reset", .desc = "Use the available reset credit that expires first", .positionals = &reset_positionals },
    .{ .name = "alias", .desc = "Set or clear account aliases", .subs = &alias_subs },
    .{ .name = "clean", .desc = "Delete backup and stale files under accounts/", .positionals = &clean_positionals },
    .{ .name = "completion", .desc = "Generate shell completion scripts", .positionals = &completion_positionals },
    .{ .name = "config", .desc = "Manage configuration", .subs = &config_subs },
    .{ .name = "app", .desc = "Launch Codex App with CLI overrides", .flags = &app_flags },
};
const empty_spec = CmdSpec{ .name = "-", .desc = "Switch to the previous active account", .flags = &dash_flags };

const Context = struct {
    spec: ?*const CmdSpec = null,
    pending: ?*const FlagSpec = null,
    pos_count: usize = 0,
    sub_pending: bool = false,
    unknown: bool = false,
    seen_buf: [32]*const FlagSpec = undefined,
    seen_len: usize = 0,

    fn seenFlags(self: *const Context) []const *const FlagSpec {
        return self.seen_buf[0..self.seen_len];
    }

    fn markFlag(self: *Context, flag: *const FlagSpec) void {
        if (self.seen_len < self.seen_buf.len) {
            self.seen_buf[self.seen_len] = flag;
            self.seen_len += 1;
        }
    }
};

fn findSpec(specs: []const CmdSpec, name: []const u8) ?*const CmdSpec {
    for (specs) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn findFlag(spec: *const CmdSpec, name: []const u8) ?*const FlagSpec {
    for (spec.flags) |*flag| {
        if (std.mem.eql(u8, flag.name, name)) return flag;
    }
    for (&help_flags) |*flag| {
        if (std.mem.eql(u8, flag.name, name)) return flag;
    }
    return null;
}

fn isGlobalFlagName(name: []const u8) bool {
    return std.mem.eql(u8, name, "-h") or
        std.mem.eql(u8, name, "--help") or
        std.mem.eql(u8, name, "-V") or
        std.mem.eql(u8, name, "--version");
}

fn resolveContext(prev: []const []const u8) Context {
    var ctx: Context = .{};
    var sub_taken = false;
    for (prev) |tok| {
        if (ctx.pending != null) {
            // A real `=` word is consumed by the parser as the flag's value,
            // so it ends the pending state like any other value token.
            ctx.pending = null;
            continue;
        }
        const spec = ctx.spec orelse {
            if (findSpec(&command_specs, tok)) |s| {
                ctx.spec = s;
                continue;
            }
            if (std.mem.eql(u8, tok, "-")) {
                ctx.spec = &empty_spec;
                continue;
            }
            if (isGlobalFlagName(tok)) {
                ctx.unknown = true;
                continue;
            }
            ctx.unknown = true;
            return ctx;
        };
        if (spec.subs.len > 0 and !sub_taken and ctx.pos_count == 0) {
            if (findSpec(spec.subs, tok)) |s| {
                ctx.spec = s;
                sub_taken = true;
                continue;
            }
            sub_taken = true;
        }
        if (tok.len > 1 and std.mem.startsWith(u8, tok, "-")) {
            if (std.mem.startsWith(u8, tok, "--")) {
                const eq = std.mem.indexOfScalar(u8, tok, '=');
                const name = if (eq) |i| tok[0..i] else tok;
                if (findFlag(spec, name)) |flag| {
                    if (eq != null and flag.value == .none) {
                        // `--flag=x` is rejected for value-less flags.
                        ctx.unknown = true;
                        continue;
                    }
                    // The parser rejects duplicated flags and conflicting or
                    // positional-blocked combinations, so the rest of the line
                    // is dead once one is seen.
                    for (ctx.seenFlags()) |seen| {
                        if (seen == flag) ctx.unknown = true;
                    }
                    if (flagBlocked(spec, flag, &ctx)) ctx.unknown = true;
                    ctx.markFlag(flag);
                    // A `--help` word is only valid on its own; extras are rejected.
                    if (std.mem.eql(u8, name, "--help")) ctx.unknown = true;
                    // A trailing `=` keeps the value pending so `--flag=<TAB>`
                    // completes joined values; the endpoint cannot tell the
                    // cursor sits right after `=` versus on a later word. A
                    // freeform flag's empty value is already consumed, so the
                    // next word is a positional.
                    if (flag.value != .none and (eq == null or (eq.? == tok.len - 1 and flag.value != .freeform))) {
                        ctx.pending = flag;
                    }
                } else {
                    ctx.unknown = true;
                }
            } else {
                ctx.unknown = true;
            }
            continue;
        }
        ctx.pos_count += 1;
    }
    if (ctx.spec) |spec| {
        ctx.sub_pending = spec.subs.len > 0 and !sub_taken;
    }
    return ctx;
}

fn positionalSpec(spec: *const CmdSpec, pos_count: usize) ?*const PosSpec {
    if (pos_count < spec.positionals.len) return &spec.positionals[pos_count];
    if (spec.positionals.len > 0 and spec.positionals[spec.positionals.len - 1].repeat) {
        return &spec.positionals[spec.positionals.len - 1];
    }
    return null;
}

fn writeCand(out: *std.Io.Writer, value: []const u8, desc: []const u8, cur: []const u8, descriptions: bool) !void {
    if (!std.mem.startsWith(u8, value, cur)) return;
    if (!lineSafe(value)) return;
    if (descriptions) {
        try out.print("{s}\t", .{value});
        for (desc) |c| {
            try out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
        }
        try out.writeByte('\n');
    } else {
        try out.print("{s}\n", .{value});
    }
}

fn writeCands(out: *std.Io.Writer, cands: []const Cand, cur: []const u8, descriptions: bool) !void {
    for (cands) |cand| {
        try writeCand(out, cand.value, cand.desc, cur, descriptions);
    }
}

fn seenFlagNamed(seen: []const *const FlagSpec, name: []const u8) bool {
    for (seen) |flag| {
        if (std.mem.eql(u8, flag.name, name)) return true;
    }
    return false;
}

// Suggestions must not assemble a command the parser would reject: conflicts
// are declared on flags, and mode flags are also blocked by typed selectors.
fn flagBlocked(spec: *const CmdSpec, flag: *const FlagSpec, ctx: *const Context) bool {
    if (ctx.pos_count > 0) {
        for (spec.pos_blocks_flags) |name| {
            if (std.mem.eql(u8, flag.name, name)) return true;
        }
    }
    for (flag.conflicts) |name| {
        if (seenFlagNamed(ctx.seenFlags(), name)) return true;
    }
    for (ctx.seenFlags()) |seen| {
        for (seen.conflicts) |name| {
            if (std.mem.eql(u8, flag.name, name)) return true;
        }
    }
    return false;
}

fn writeFlagCands(out: *std.Io.Writer, spec: *const CmdSpec, cur: []const u8, ctx: *const Context, descriptions: bool) !void {
    outer: for (spec.flags) |*flag| {
        for (ctx.seenFlags()) |s| if (s == flag) continue :outer;
        if (flagBlocked(spec, flag, ctx)) continue :outer;
        try writeCand(out, flag.name, flag.desc, cur, descriptions);
    }
    // Help flags are only valid as the sole argument after a command name.
    if (spec.accepts_help and ctx.pos_count == 0 and ctx.seen_len == 0) {
        for (&help_flags) |*flag| {
            try writeCand(out, flag.name, flag.desc, cur, descriptions);
        }
    }
}

fn writeSpecNames(out: *std.Io.Writer, specs: []const CmdSpec, cur: []const u8, skip_help: bool, descriptions: bool) !void {
    for (specs) |spec| {
        if (skip_help and std.mem.eql(u8, spec.name, "help")) continue;
        try writeCand(out, spec.name, spec.desc, cur, descriptions);
    }
}

fn writeFlagValueCands(out: *std.Io.Writer, flag: *const FlagSpec, cur: []const u8, descriptions: bool) !u6 {
    switch (flag.value) {
        .choices => {
            for (flag.choices) |choice| try writeCand(out, choice, choice, cur, descriptions);
            return static_directive;
        },
        .path => return Directive.none,
        .dir => return Directive.filter_dirs,
        else => return static_directive,
    }
}

fn writeInlineFlagValueCands(out: *std.Io.Writer, flag: *const FlagSpec, cur: []const u8, descriptions: bool) !u6 {
    const eq = std.mem.indexOfScalar(u8, cur, '=') orelse return static_directive;
    if (flag.value == .choices) {
        for (flag.choices) |choice| {
            var buf: [128]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}={s}", .{ cur[0..eq], choice }) catch continue;
            try writeCand(out, full, choice, cur, descriptions);
        }
    }
    return switch (flag.value) {
        .path => Directive.none,
        .dir => Directive.filter_dirs,
        else => static_directive,
    };
}

fn inlineFlagSpec(spec: ?*const CmdSpec, cur: []const u8) ?*const FlagSpec {
    const s = spec orelse return null;
    if (!std.mem.startsWith(u8, cur, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, cur, '=') orelse return null;
    return findFlag(s, cur[0..eq]);
}

fn writePositionalCands(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    spec: *const CmdSpec,
    pos: *const PosSpec,
    cur: []const u8,
    ctx: *const Context,
    descriptions: bool,
) !u6 {
    var blocked = false;
    for (pos.blocked_by) |name| {
        if (seenFlagNamed(ctx.seenFlags(), name)) blocked = true;
    }
    switch (pos.kind) {
        .account => {
            if (!blocked) {
                try writeAccountCandidates(out, allocator, codex_home, cur, descriptions);
                try writeCands(out, pos.literals, cur, descriptions);
            }
        },
        .literal => if (!blocked) try writeCands(out, pos.literals, cur, descriptions),
        .command_name => try writeSpecNames(out, &command_specs, cur, true, descriptions),
        .freeform => {},
        .path => {
            try writeFlagCands(out, spec, cur, ctx, descriptions);
            return Directive.none;
        },
        .dir => {
            try writeFlagCands(out, spec, cur, ctx, descriptions);
            return Directive.filter_dirs;
        },
    }
    return static_directive;
}

pub fn writeCompleteResponse(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    args: []const []const u8,
    descriptions: bool,
) !void {
    var cur: []const u8 = "";
    var prev = args;
    if (prev.len > 0) {
        cur = prev[prev.len - 1];
        // PowerShell <7.2 sends a literal `""` sentinel for an empty word; if it
        // ever arrives unnormalized, treat it as an empty prefix.
        if (std.mem.eql(u8, cur, "\"\"")) cur = "";
        prev = prev[0 .. prev.len - 1];
    }

    const ctx = resolveContext(prev);
    var directive: u6 = static_directive;

    if (ctx.unknown) {
        // No meaningful completions for an unrecognized command word.
    } else if (ctx.pending) |flag| {
        directive = try writeFlagValueCands(out, flag, cur, descriptions);
    } else if (inlineFlagSpec(ctx.spec, cur)) |flag| {
        // A joined `--flag=value` word is still one flag occurrence: an already
        // used or conflicting flag must not offer values the parser rejects.
        if (!seenFlagNamed(ctx.seenFlags(), flag.name) and !flagBlocked(ctx.spec.?, flag, &ctx)) {
            directive = try writeInlineFlagValueCands(out, flag, cur, descriptions);
        }
    } else if (ctx.spec == null) {
        if (std.mem.startsWith(u8, cur, "-") and cur.len > 0) {
            try writeCands(out, &global_cands, cur, descriptions);
        } else {
            try writeSpecNames(out, &command_specs, cur, false, descriptions);
            try writeCands(out, &dash_cands, cur, descriptions);
        }
    } else {
        const spec = ctx.spec.?;
        if (spec == &empty_spec) {
            // `codex-auth -` accepts only the one-shot switch flags, and no
            // positional word may follow them.
            if (ctx.pos_count == 0 and (cur.len == 0 or std.mem.startsWith(u8, cur, "-")))
                try writeFlagCands(out, spec, cur, &ctx, descriptions);
        } else if (cur.len > 0 and std.mem.startsWith(u8, cur, "-")) {
            try writeFlagCands(out, spec, cur, &ctx, descriptions);
            if (positionalSpec(spec, ctx.pos_count)) |pos| try writeCands(out, pos.literals, cur, descriptions);
        } else if (ctx.sub_pending) {
            try writeSpecNames(out, spec.subs, cur, false, descriptions);
        } else if (positionalSpec(spec, ctx.pos_count)) |pos| {
            directive = try writePositionalCands(out, allocator, codex_home, spec, pos, cur, &ctx, descriptions);
            // A repeatable positional still allows the non-positional flags.
            if (pos.repeat) try writeFlagCands(out, spec, cur, &ctx, descriptions);
        } else {
            try writeFlagCands(out, spec, cur, &ctx, descriptions);
        }
    }
    try out.print(":{d}\n", .{directive});
}

pub fn writeAccountCandidates(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    cur: []const u8,
    descriptions: bool,
) !void {
    const home = codex_home orelse return;
    var reg = registry.loadRegistry(allocator, home) catch return;
    defer reg.deinit(allocator);

    var display = display_rows.buildDisplayRows(allocator, &reg, null) catch return;
    defer display.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iter = seen.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (display.selectable_row_indices) |row_idx| {
        const account_idx = display.rows[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];
        const account_cell = display.rows[row_idx].account_cell;

        try writeUniqueCandidate(out, &seen, selectorHint(&reg, rec), account_cell, cur, allocator, descriptions);
    }
}

// One candidate per account: the user-chosen alias when it uniquely identifies
// the account, else a unique email, else the always-unique account key. Shared
// labels are ambiguous selectors, so they are never offered. A label that
// parses as a flag (for example `--all`) would trigger a command action
// instead of selecting the account, and a `:`-leading label is swallowed by
// the shells' directive-line parsing — neither is offered.
fn selectorHint(reg: *const registry.Registry, rec: *const registry.AccountRecord) []const u8 {
    if (usableHint(reg, rec.alias)) return rec.alias;
    if (usableHint(reg, rec.email)) return rec.email;
    return rec.account_key;
}

fn usableHint(reg: *const registry.Registry, label: []const u8) bool {
    if (label.len == 0 or label[0] == '-' or label[0] == ':' or !lineSafe(label)) return false;
    // Account keys resolve before labels, so a label that spells another
    // account's key would act on that account, not this one. Bare digits
    // resolve as displayed row numbers for the same reason.
    if (registry.findAccountIndexByAccountKey(reg, label) != null) return false;
    if (query.selectorIsBareRowNumber(label)) return false;
    return labelMatchCount(reg, label) == 1;
}

// Candidate rows are `value<TAB>description` lines; a value carrying control
// characters would split the row and offer a truncated alias.
fn lineSafe(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

fn labelMatchCount(reg: *const registry.Registry, label: []const u8) usize {
    var count: usize = 0;
    for (reg.accounts.items) |*other| {
        const alias_hit = other.alias.len != 0 and std.ascii.eqlIgnoreCase(other.alias, label);
        const email_hit = std.ascii.eqlIgnoreCase(other.email, label);
        if (alias_hit or email_hit) count += 1;
    }
    return count;
}

fn writeUniqueCandidate(
    out: *std.Io.Writer,
    seen: *std.StringHashMap(void),
    value: []const u8,
    description: []const u8,
    cur: []const u8,
    allocator: std.mem.Allocator,
    descriptions: bool,
) !void {
    if (value.len == 0) return;
    if (!std.mem.startsWith(u8, value, cur)) return;
    if (!lineSafe(value)) return;
    if (seen.contains(value)) return;

    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    try writeCand(out, value, description, cur, descriptions);
    try seen.putNoClobber(owned_value, {});
}
