#!/usr/bin/env bash
# Renders the `list --live` reset credits rail and the `codex-auth reset` output
# lines for BOTH platform glyph sets side by side, so the Windows rendering can
# be reviewed without a Windows machine. The rail is drawn by the real renderer
# through a temporary Zig program; nothing here is a hand-written mock.
#
# Expiry times are rendered in this machine's local time zone, the same way the
# live rail does it.
#
#   scripts/dev/reset-rail-preview.sh            render every preview case
#   scripts/dev/reset-rail-preview.sh --help     show this help
set -euo pipefail

case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    printf 'unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

preview_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$preview_dir"
}
trap cleanup EXIT

cat > "$preview_dir/preview.zig" <<'ZIG'
const std = @import("std");
const codex_auth = @import("codex_auth");
const cli = codex_auth.cli;
const io_util = codex_auth.core.io_util;

const Card = cli.reset_credits_panel.AvailableCard;
const Options = cli.reset_credits_panel.RenderOptions;

fn show(
    allocator: std.mem.Allocator,
    label: []const u8,
    context: ?[]const u8,
    cards: []const Card,
    opts: Options,
) !void {
    var rail: std.Io.Writer.Allocating = .init(allocator);
    defer rail.deinit();
    const lines = try cli.reset_credits_panel.render(allocator, &rail.writer, cards, opts);

    // `io_util.Stdout` borrows its own buffer, so it must stay in this frame.
    var out: io_util.Stdout = undefined;
    out.init();
    try out.out().print("\n== {s} ==\n", .{label});
    if (context) |row| try out.out().print("{s}\n", .{row});
    try out.out().print("{s}", .{rail.written()});
    try out.out().print("   [{d} rail lines | indent {d} | width {d} | windows={s} | color={s}]\n", .{
        lines,
        opts.indent,
        opts.max_cols,
        if (opts.is_windows) "yes" else "no",
        if (opts.use_color) "yes" else "no",
    });
    try out.out().flush();
}

fn showResetLines(allocator: std.mem.Allocator, is_windows: bool) !void {
    const Case = struct {
        label: []const u8,
        already_used: bool,
        remaining: usize,
        next_expiry: ?[]const u8,
    };
    const cases = [_]Case{
        .{ .label = "success, one card left", .already_used = false, .remaining = 1, .next_expiry = "01-01 08:00" },
        .{ .label = "success, that was the last card", .already_used = false, .remaining = 0, .next_expiry = null },
        .{ .label = "backend says already_redeemed", .already_used = true, .remaining = 0, .next_expiry = null },
        .{ .label = "next card has no expiry", .already_used = false, .remaining = 2, .next_expiry = null },
    };

    var out: io_util.Stdout = undefined;
    out.init();
    try out.out().print("\n== codex-auth reset summary line (windows={s}) ==\n", .{if (is_windows) "yes" else "no"});
    for (cases) |case| {
        const line = try cli.output.resetSummaryLineAlloc(allocator, case.already_used, case.remaining, case.next_expiry, is_windows);
        defer allocator.free(line);
        try out.out().print("  {s}\n    {s}\n", .{ case.label, line });
    }
    try out.out().flush();
}

test "reset credits rail preview" {
    const gpa = std.testing.allocator;

    // Derive the sample expiry through the same parser the rail uses, so the
    // rendered `MM-DD HH:MM` and the relative countdown agree.
    const soon = codex_auth.time.timestamp.parseIso8601("2026-11-01T00:00:00Z") orelse return error.TestUnexpectedResult;
    const preview_now = soon - 9 * 86400;

    const cards = [_]Card{
        .{ .id = "soon", .title = "Full reset (Weekly + 5 hr)", .expires_at = "2026-11-01T00:00:00Z", .epoch = soon },
        .{ .id = "undated", .title = null, .expires_at = null, .epoch = null },
    };
    const remaining = [_]Card{
        .{ .id = "undated", .title = null, .expires_at = null, .epoch = null },
    };
    // What the rail looks like right after "soon" was consumed: the spent
    // ghost keeps its sorted slot tagged `redeemed`, no status line.
    const spent = [_]cli.reset_credits_panel.Selection.SpentCard{
        .{ .title = "Full reset (Weekly + 5 hr)", .epoch = soon },
    };
    const no_cards = [_]Card{};
    const row = "*1   work-main@example…              Business  100%          58% (14:20)";

    inline for ([_]bool{ false, true }) |is_windows| {
        const platform = if (is_windows) "windows" else "linux/macos";

        try show(gpa, "idle rail, " ++ platform, row, &cards, .{
            .max_cols = 100,
            .now = preview_now,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "armed for a second Enter, " ++ platform, row, &cards, .{
            .max_cols = 100,
            .now = preview_now,
            .confirm_pending = true,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "after a successful redeem, " ++ platform, row, &remaining, .{
            .max_cols = 100,
            .now = preview_now,
            .card_cursor = 0,
            .spent_cards = &spent,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "after a failed redeem, " ++ platform, row, &cards, .{
            .max_cols = 100,
            .now = preview_now,
            .status = "redeem failed (HTTP 500)",
            .status_kind = .fail,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "nothing to reset, " ++ platform, row, &cards, .{
            .max_cols = 100,
            .now = preview_now,
            .status = "usage does not need a reset right now",
            .status_kind = .info,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "spent card, empty list, " ++ platform, row, &no_cards, .{
            .max_cols = 100,
            .now = preview_now,
            .status = "reset credit is no longer available; refresh to see current resets",
            .status_kind = .fail,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "narrow terminal (46 columns), " ++ platform, null, &cards, .{
            .max_cols = 46,
            .now = preview_now,
            .confirm_pending = true,
            .indent = 6,
            .is_windows = is_windows,
        });
        try show(gpa, "color roles (needs a color terminal), " ++ platform, row, &remaining, .{
            .max_cols = 100,
            .now = preview_now,
            .spent_cards = &spent,
            .indent = 6,
            .is_windows = is_windows,
            .use_color = true,
        });

        try showResetLines(gpa, is_windows);
    }
}
ZIG

zig test \
  --dep codex_auth \
  -Mroot="$preview_dir/preview.zig" \
  -Mcodex_auth="$repo_root/src/root.zig" \
  -lc \
  --cache-dir "$repo_root/.zig-cache" \
  --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}" \
  --name reset-rail-preview
