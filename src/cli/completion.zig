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

pub fn printCompleteResponse(
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    args: []const []const u8,
) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    try writeCompleteResponse(out, allocator, codex_home, args);
    try out.flush();
}

pub fn writeCompletion(out: *std.Io.Writer, shell: types.CompletionShell) !void {
    switch (shell) {
        .bash => try out.writeAll(bash_script),
        .zsh => try out.writeAll(zsh_script),
        .fish => try out.writeAll(fish_script),
    }
}

const bash_script =
    \\_codex_auth_complete() {
    \\    COMPREPLY=()
    \\    local i w buf="" cur tail before directive=0 value desc out
    \\    local -a argv cands
    \\    for (( i=1; i<=COMP_CWORD; i++ )); do
    \\        w="${COMP_WORDS[i]}"
    \\        if [[ "$w" == ":" || "$w" == "=" || "$buf" == *[:=] ]]; then
    \\            buf+="$w"
    \\            continue
    \\        fi
    \\        (( i > 1 )) && argv+=("$buf")
    \\        buf="$w"
    \\    done
    \\    argv+=("$buf")
    \\    out="$(codex-auth __complete "${argv[@]}" 2>/dev/null)"
    \\    while IFS=$'\t' read -r value desc; do
    \\        case "$value" in
    \\            :*) directive="${value#:}" ;;
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
    \\        COMPREPLY=( $(compgen -d -- "$tail") )
    \\    elif (( ${#cands[@]} )); then
    \\        COMPREPLY=( $(compgen -W "${cands[*]}" -- "$cur") )
    \\        if [[ -n "$before" ]]; then
    \\            COMPREPLY=("${COMPREPLY[@]#"$before"}")
    \\        fi
    \\    fi
    \\    (( directive & 2 )) && compopt -o nospace 2>/dev/null
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
    \\  local out value desc
    \\  local -a argv cands descs
    \\  local directive=0
    \\  argv=("${words[2,CURRENT]}")
    \\  out="$(codex-auth __complete "${argv[@]}" 2>/dev/null)"
    \\  while IFS=$'\t' read -r value desc; do
    \\    case "$value" in
    \\      (:*) directive="${value#:}" ;;
    \\      (*)  cands+=("$value"); descs+=("${desc:-$value}") ;;
    \\    esac
    \\  done <<< "$out"
    \\  (( directive == 1 )) && return 1
    \\  if (( directive & 16 )); then
    \\    _files -/
    \\    return
    \\  fi
    \\  if (( ${#cands[@]} > 0 )); then
    \\    if (( directive & 2 )); then
    \\      compadd -Q -S '' -d descs -- "${cands[@]}"
    \\    else
    \\      compadd -Q -d descs -- "${cands[@]}"
    \\    fi
    \\  fi
    \\  (( directive & 4 )) || _files
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
    \\    if test (count $tokens) -eq 0; or test "$tokens[-1]" != "$cur"
    \\        set -a tokens "$cur"
    \\    end
    \\    set -l directive 0
    \\    for line in (codex-auth __complete $tokens 2>/dev/null)
    \\        if string match -q ':*' -- $line
    \\            set directive (string sub -s 2 -- $line)
    \\        else
    \\            echo $line
    \\        end
    \\    end
    \\    test $directive -eq 1; and return
    \\    set -l dirs (math -s0 "floor($directive / 16) % 2" 2>/dev/null)
    \\    if test "$dirs" = "1"
    \\        __fish_complete_path
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
};
const Cand = struct { value: []const u8, desc: []const u8 };
const PosSpec = struct {
    kind: PosKind,
    literals: []const Cand = &.{},
    repeat: bool = false,
};
const CmdSpec = struct {
    name: []const u8,
    desc: []const u8,
    flags: []const FlagSpec = &.{},
    subs: []const CmdSpec = &.{},
    positionals: []const PosSpec = &.{},
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
    .{ .name = "--live", .desc = "Open a live-updating table" },
    .{ .name = "--active", .desc = "Refresh only the active account before rendering" },
    .{ .name = "--api", .desc = "Load usage and account data from APIs" },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only" },
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document" },
};
const login_flags = [_]FlagSpec{
    .{ .name = "--device-auth", .desc = "Run codex login with device auth" },
};
const import_flags = [_]FlagSpec{
    .{ .name = "--alias", .desc = "Set an alias for a single imported account", .value = .freeform },
    .{ .name = "--cpa", .desc = "Import CPA flat token JSON" },
    .{ .name = "--purge", .desc = "Rebuild registry.json from auth files" },
};
const export_flags = [_]FlagSpec{
    .{ .name = "--cpa", .desc = "Export CPA flat token JSON" },
};
const switch_flags = [_]FlagSpec{
    .{ .name = "--live", .desc = "Open the live switch UI" },
    .{ .name = "--api", .desc = "Load usage and account data from APIs" },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only" },
    .{ .name = "--json", .desc = "Emit one machine-readable JSON document for non-interactive switch" },
};
const remove_flags = [_]FlagSpec{
    .{ .name = "--live", .desc = "Open the live remove UI" },
    .{ .name = "--api", .desc = "Load usage and account data from APIs" },
    .{ .name = "--skip-api", .desc = "Load usage and account data from local data only" },
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
const clean_cands = [_]Cand{.{ .value = "background", .desc = "Delete stale background files" }};
const shell_cands = [_]Cand{
    .{ .value = "bash", .desc = "Print Bash completion script" },
    .{ .value = "zsh", .desc = "Print Zsh completion script" },
    .{ .value = "fish", .desc = "Print Fish completion script" },
};

const help_positionals = [_]PosSpec{.{ .kind = .command_name }};
const import_positionals = [_]PosSpec{.{ .kind = .path }};
const export_positionals = [_]PosSpec{.{ .kind = .path }};
const switch_positionals = [_]PosSpec{.{ .kind = .account, .literals = &dash_cands }};
const remove_positionals = [_]PosSpec{.{ .kind = .account, .repeat = true }};
const clean_positionals = [_]PosSpec{.{ .kind = .literal, .literals = &clean_cands }};
const completion_positionals = [_]PosSpec{.{ .kind = .literal, .literals = &shell_cands }};
const alias_set_positionals = [_]PosSpec{ .{ .kind = .account }, .{ .kind = .freeform } };
const alias_clear_positionals = [_]PosSpec{.{ .kind = .account }};

const alias_subs = [_]CmdSpec{
    .{ .name = "set", .desc = "Set one stored account alias", .positionals = &alias_set_positionals },
    .{ .name = "clear", .desc = "Clear one stored account alias", .positionals = &alias_clear_positionals },
};
const config_subs = [_]CmdSpec{
    .{ .name = "live", .desc = "Manage live refresh settings", .flags = &config_live_flags },
};

const command_specs = [_]CmdSpec{
    .{ .name = "help", .desc = "Show command-specific help", .positionals = &help_positionals },
    .{ .name = "list", .desc = "List available accounts", .flags = &list_flags },
    .{ .name = "login", .desc = "Login and add the current account", .flags = &login_flags },
    .{ .name = "import", .desc = "Import auth files or rebuild the registry", .flags = &import_flags, .positionals = &import_positionals },
    .{ .name = "export", .desc = "Export stored account auth files", .flags = &export_flags, .positionals = &export_positionals },
    .{ .name = "switch", .desc = "Switch the active account", .flags = &switch_flags, .positionals = &switch_positionals },
    .{ .name = "remove", .desc = "Remove one or more accounts", .flags = &remove_flags, .positionals = &remove_positionals },
    .{ .name = "alias", .desc = "Set or clear account aliases", .subs = &alias_subs },
    .{ .name = "clean", .desc = "Delete backup and stale files under accounts/", .positionals = &clean_positionals },
    .{ .name = "completion", .desc = "Generate shell completion scripts", .positionals = &completion_positionals },
    .{ .name = "config", .desc = "Manage configuration", .subs = &config_subs },
    .{ .name = "app", .desc = "Launch Codex App with CLI overrides", .flags = &app_flags },
};
const empty_spec = CmdSpec{ .name = "-", .desc = "Switch to the previous active account" };

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
            if (!std.mem.eql(u8, tok, "=")) ctx.pending = null;
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
            if (isGlobalFlagName(tok)) continue;
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
        if (std.mem.startsWith(u8, tok, "-") and tok.len > 1) {
            if (std.mem.startsWith(u8, tok, "--")) {
                const eq = std.mem.indexOfScalar(u8, tok, '=');
                const name = if (eq) |i| tok[0..i] else tok;
                if (findFlag(spec, name)) |flag| {
                    ctx.markFlag(flag);
                    if (flag.value != .none and (eq == null or eq.? == tok.len - 1)) {
                        ctx.pending = flag;
                    }
                }
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

fn writeCand(out: *std.Io.Writer, value: []const u8, desc: []const u8, cur: []const u8) !void {
    if (!std.mem.startsWith(u8, value, cur)) return;
    try out.print("{s}\t{s}\n", .{ value, desc });
}

fn writeCands(out: *std.Io.Writer, cands: []const Cand, cur: []const u8) !void {
    for (cands) |cand| try writeCand(out, cand.value, cand.desc, cur);
}

fn writeFlagCands(out: *std.Io.Writer, spec: *const CmdSpec, cur: []const u8, seen: []const *const FlagSpec) !void {
    outer: for (spec.flags) |*flag| {
        for (seen) |s| if (s == flag) continue :outer;
        try writeCand(out, flag.name, flag.desc, cur);
    }
    outer: for (&help_flags) |*flag| {
        for (seen) |s| if (s == flag) continue :outer;
        try writeCand(out, flag.name, flag.desc, cur);
    }
}

fn writeSpecNames(out: *std.Io.Writer, specs: []const CmdSpec, cur: []const u8) !void {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.name, "help")) continue;
        try writeCand(out, spec.name, spec.desc, cur);
    }
}

fn writeFlagValueCands(out: *std.Io.Writer, flag: *const FlagSpec, cur: []const u8) !u6 {
    switch (flag.value) {
        .choices => {
            for (flag.choices) |choice| try writeCand(out, choice, choice, cur);
            return static_directive;
        },
        .path => return Directive.none,
        .dir => return Directive.filter_dirs,
        else => return static_directive,
    }
}

fn writeInlineFlagValueCands(out: *std.Io.Writer, flag: *const FlagSpec, cur: []const u8) !u6 {
    const eq = std.mem.indexOfScalar(u8, cur, '=') orelse return static_directive;
    if (flag.value == .choices) {
        for (flag.choices) |choice| {
            var buf: [128]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}={s}", .{ cur[0..eq], choice }) catch continue;
            try writeCand(out, full, choice, cur);
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
    seen: []const *const FlagSpec,
) !u6 {
    switch (pos.kind) {
        .account => {
            try writeAccountCandidates(out, allocator, codex_home, cur);
            try writeCands(out, pos.literals, cur);
        },
        .literal => try writeCands(out, pos.literals, cur),
        .command_name => try writeSpecNames(out, &command_specs, cur),
        .freeform => {},
        .path => {
            try writeFlagCands(out, spec, cur, seen);
            return Directive.none;
        },
        .dir => {
            try writeFlagCands(out, spec, cur, seen);
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
) !void {
    var cur: []const u8 = "";
    var prev = args;
    if (prev.len > 0) {
        cur = prev[prev.len - 1];
        prev = prev[0 .. prev.len - 1];
    }

    const ctx = resolveContext(prev);
    var directive: u6 = static_directive;

    if (ctx.unknown) {
        // No meaningful completions for an unrecognized command word.
    } else if (ctx.pending) |flag| {
        directive = try writeFlagValueCands(out, flag, cur);
    } else if (inlineFlagSpec(ctx.spec, cur)) |flag| {
        directive = try writeInlineFlagValueCands(out, flag, cur);
    } else if (ctx.spec == null) {
        if (std.mem.startsWith(u8, cur, "-") and cur.len > 0) {
            try writeCands(out, &global_cands, cur);
        } else {
            try writeSpecNames(out, &command_specs, cur);
            try writeCands(out, &dash_cands, cur);
        }
    } else {
        const spec = ctx.spec.?;
        if (spec == &empty_spec) {
            // `codex-auth -` takes no further arguments.
        } else if (cur.len > 0 and std.mem.startsWith(u8, cur, "-")) {
            try writeFlagCands(out, spec, cur, ctx.seenFlags());
            if (positionalSpec(spec, ctx.pos_count)) |pos| try writeCands(out, pos.literals, cur);
        } else if (ctx.sub_pending) {
            try writeSpecNames(out, spec.subs, cur);
        } else if (positionalSpec(spec, ctx.pos_count)) |pos| {
            directive = try writePositionalCands(out, allocator, codex_home, spec, pos, cur, ctx.seenFlags());
        } else {
            try writeFlagCands(out, spec, cur, ctx.seenFlags());
        }
    }
    try out.print(":{d}\n", .{directive});
}

pub fn writeAccountCandidates(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    cur: []const u8,
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

    for (display.selectable_row_indices, 0..) |row_idx, displayed_idx| {
        const account_idx = display.rows[row_idx].account_index orelse continue;
        const rec = &reg.accounts.items[account_idx];
        const account_cell = display.rows[row_idx].account_cell;

        const composite = try std.fmt.allocPrint(allocator, "{d:0>2}:{s}", .{ displayed_idx + 1, rec.email });
        try writeUniqueCandidate(out, &seen, composite, account_cell, cur, allocator);
        allocator.free(composite);
        if (rec.alias.len != 0) {
            try writeUniqueCandidate(out, &seen, rec.alias, account_cell, cur, allocator);
        }
        try writeUniqueCandidate(out, &seen, rec.email, account_cell, cur, allocator);
    }
}

fn writeUniqueCandidate(
    out: *std.Io.Writer,
    seen: *std.StringHashMap(void),
    value: []const u8,
    description: []const u8,
    cur: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (value.len == 0) return;
    if (!std.mem.startsWith(u8, value, cur)) return;
    if (seen.contains(value)) return;

    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);

    try out.print("{s}\t{s}\n", .{ value, description });
    try seen.putNoClobber(owned_value, {});
}
