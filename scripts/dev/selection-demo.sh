#!/usr/bin/env bash
# Manual test bench for the selection/cursor/highlight logic, driven by pure
# local registry data. No mock backend, no fixtures, no network: the table and
# the reset-credit rail render straight from `last_usage` baked into
# registry.json, and every CLI run uses `--skip-api`.
#
# All auth snapshots are API-key kind on purpose: the rail's redeem step
# requires a ChatGPT snapshot, so a double `Enter` fails locally with
# `MissingAuth` before any request leaves the machine. This demo is about the
# row cursor and the credit highlight, not about redemption.
#
#   scripts/dev/selection-demo.sh                       drive the cursor yourself
#   scripts/dev/selection-demo.sh --screen switch       same, on the switch picker
#   scripts/dev/selection-demo.sh --screen remove       same, on the remove picker
#   scripts/dev/selection-demo.sh --drive               scripted tmux session, frames printed
#   scripts/dev/selection-demo.sh --assert              same session, asserted as a smoke test
#   scripts/dev/selection-demo.sh --keep                keep the CODEX_HOME for inspection
#
# What to look for by hand (interactive mode):
#   - The cursor `>` opens on the active account (zeta, row 12), covering the
#     `*` marker; move off it and `*` reappears while `>` tracks the cursor.
#     They are independent markers: moving the cursor never moves `*`.
#   - Every single j / k must move `>` exactly one row, on the very next
#     frame — no trailing highlight, no doubled cursor. Up / Down scroll the
#     viewport instead, exactly as the footer says; only inside the rail do
#     Up / Down move the credit highlight.
#   - Hold a key down: `>` must end on the row the key count implies.
#   - Enter opens the rail directly under the `>` row; inside the rail,
#     j / k move the credit highlight without moving the row cursor.
#   - Esc closes the rail and the row cursor is exactly where you left it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

screen="list"
drive=0
assert_frames=0
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --screen)
      screen="${2:-}"
      [ "$screen" = list ] || [ "$screen" = switch ] || [ "$screen" = remove ] || {
        printf -- '--screen needs list, switch or remove\n' >&2
        exit 2
      }
      shift 2
      ;;
    --drive) drive=1; shift ;;
    --assert) drive=1; assert_frames=1; shift ;;
    --keep) keep=1; shift ;;
    -h | --help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "$drive" = 1 ] && [ "$screen" != list ]; then
  printf -- '--drive/--assert cover the list screen only (interactive --screen switch/remove are manual by nature).\n' >&2
  exit 2
fi

zig build

demo_home="$(mktemp -d)"
tmux_session=""
cleanup() {
  if [ -n "$tmux_session" ]; then
    tmux kill-session -t "$tmux_session" 2>/dev/null || true
  fi
  if [ "$keep" = 0 ]; then
    rm -rf "$demo_home"
  fi
}
trap cleanup EXIT

# --- pure-data seed: registry + apikey auth snapshots, nothing else ---------

demo_b64url() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

# selection_card <id> <expires_at|null> <title|null>
selection_card() {
  local expires="null" title="null"
  [ "$2" != "null" ] && expires="\"$2\""
  [ "$3" != "null" ] && title="\"$3\""
  printf '{ "id": "%s", "status": "available", "expires_at": %s, "title": %s }' "$1" "$expires" "$title"
}

# selection_account <user> <account_id> <email> <alias> <plan> <5h> <weekly>
#                   <available_count> <cards-json>
selection_account() {
  local user="$1" account="$2" email="$3" alias="$4" plan="$5"
  local primary="$6" weekly="$7" count="$8" cards="$9"
  local key="$user::$account"

  # API-key snapshot: the redeem step bails out locally (MissingAuth), so no
  # key combination in this demo can produce a network request.
  printf '{"OPENAI_API_KEY":"sk-demo-key"}\n' \
    > "$demo_home/accounts/$(printf '%s' "$key" | demo_b64url).auth.json"

  local usage
  usage=$(cat <<JSON
    {
      "primary": { "used_percent": $primary, "window_minutes": 300, "resets_at": 4102444800 },
      "secondary": { "used_percent": $weekly, "window_minutes": 10080, "resets_at": 4103049600 },
      "credits": null,
      "reset_credits": $count,
      "reset_credit": $cards,
      "plan_type": "$plan"
    }
JSON
)

  local entry
  entry=$(cat <<JSON
    {
      "account_key": "$key",
      "chatgpt_account_id": "$account",
      "chatgpt_user_id": "$user",
      "email": "$email",
      "alias": "$alias",
      "account_name": null,
      "plan": "$plan",
      "auth_mode": "apikey",
      "created_at": 0,
      "last_used_at": null,
      "last_usage_at": null,
      "last_usage": $usage
    }
JSON
)
  if [ -n "${_sel_accounts:-}" ]; then
    _sel_accounts="$_sel_accounts,"$'\n'"$entry"
  else
    _sel_accounts="$entry"
  fi
}

# seed_selection_home <CODEX_HOME>
#
# The live table sorts accounts by display label, so the rendered row order is
# (list --live data rows, 1-based):
#   1 alpha  (2 cards)      5 eta    (2 cards)   9  iota-a (group child)
#   2 beta   (0 cards)      6 gamma  (1 card)    10 iota-b (group child)
#   3 delta  (0 cards)      7 kappa  (1 card)    11 theta  (0 cards)
#   4 eps    (1 card, `-`)  8 lambda (0 cards)   12 zeta   ACTIVE, 3 cards
seed_selection_home() {
  demo_home="$1"
  mkdir -p "$demo_home/accounts"
  _sel_accounts=""

  selection_account user-alpha account-alpha alpha@example.com alpha plus 91 44 2 \
    "[$(selection_card card-alpha-soon 2026-11-01T00:00:00Z "Full reset (Weekly + 5 hr)"), $(selection_card card-alpha-open null "Later card")]"
  selection_account user-beta account-beta beta@example.com beta plus 12 8 0 "[]"
  selection_account user-gamma account-gamma gamma@example.com gamma pro 33 21 1 \
    "[$(selection_card card-gamma 2026-12-01T00:00:00Z "Workspace reset")]"
  selection_account user-delta account-delta delta@example.com delta plus 47 51 0 "[]"
  selection_account user-eps account-eps eps@example.com eps pro 26 62 1 \
    "[$(selection_card card-eps null "Solo card")]"
  selection_account user-zeta account-zeta zeta@example.com zeta plus 88 79 3 \
    "[$(selection_card card-zeta-1 2026-11-01T00:00:00Z "Full reset (Weekly + 5 hr)"), $(selection_card card-zeta-2 2026-11-15T00:00:00Z "Full reset (Weekly + 5 hr)"), $(selection_card card-zeta-3 null "Spare card")]"
  selection_account user-eta account-eta eta@example.com eta business 55 40 2 \
    "[$(selection_card card-eta-1 2026-12-01T00:00:00Z "Workspace reset"), $(selection_card card-eta-2 null "Later card")]"
  selection_account user-theta account-theta theta@example.com theta plus 5 3 0 "[]"
  selection_account user-iota-a account-iota-a shared@example.com iota-a business 61 58 1 \
    "[$(selection_card card-iota-a 2026-12-10T00:00:00Z "Workspace reset")]"
  selection_account user-iota-b account-iota-b shared@example.com iota-b business 72 66 1 \
    "[$(selection_card card-iota-b 2026-12-20T00:00:00Z "Workspace reset")]"
  selection_account user-kappa account-kappa kappa@example.com kappa pro 44 39 1 \
    "[$(selection_card card-kappa 2027-01-01T00:00:00Z "Full reset (Weekly + 5 hr)")]"
  selection_account user-lambda account-lambda lambda@example.com lambda plus 18 11 0 "[]"

  cat > "$demo_home/accounts/registry.json" <<JSON
{
  "schema_version": 4,
  "active_account_key": "user-zeta::account-zeta",
  "previous_active_account_key": null,
  "active_account_activated_at_ms": null,
  "interval_seconds": 60,
  "accounts": [
$_sel_accounts
  ]
}
JSON
}

seed_selection_home "$demo_home"
cli="$repo_root/zig-out/bin/codex-auth"

cat <<INFO
Isolated CODEX_HOME : $demo_home
Data source         : registry.json only (--skip-api, no backend, no network)
Active account      : zeta (row 12, table sorts by label) — the cursor opens
                      there, so ">" and "*" share that row at boot
Redeem              : intentionally impossible (apikey snapshots fail fast,
                      zero requests); this demo tests selection, not redemption

Manual checks in list --live:
  j / k               ">" moves exactly one row per press, immediately
  Up / Down           scroll the viewport; inside the rail they move the credit
                      highlight instead
  hold or paste keys  ">" ends on the row the key count implies
  Enter               rail opens under the ">" row (needs a credits row)
  rail j / k          credit ">" moves, the row ">" stays on its anchor
  Esc / q             close the rail / quit; the row cursor is preserved
  --screen switch     same table as the switch picker; 1-9 jumps to a row
  --screen remove     checkbox picker; Space toggles [x], 1-9 jumps
INFO

# --- scripted session --------------------------------------------------------

assert_failures=0
quit_failed=0
esc_arrow_failed=0

frame_has() { # frame_has <frame> <regex> <what it proves>
  local frame="$demo_home/frames/$1.txt"
  if [ -f "$frame" ] && grep -qE -- "$2" "$frame"; then
    printf 'ok    %-26s %s\n' "$1" "$3"
  else
    printf 'FAIL  %-26s %s (expected: %s)\n' "$1" "$3" "$2"
    assert_failures=$((assert_failures + 1))
  fi
}

frame_count() { # frame_count <frame> <regex> <count> <what it proves>
  local frame="$demo_home/frames/$1.txt"
  local found
  found=$(grep -cE -- "$2" "$frame" 2>/dev/null || true)
  if [ "$found" = "$3" ]; then
    printf 'ok    %-26s %s\n' "$1" "$4"
  else
    printf 'FAIL  %-26s %s (expected %s, found %s)\n' "$1" "$4" "$3" "$found"
    assert_failures=$((assert_failures + 1))
  fi
}

# expect_cursor <frame> <1-based data row>
# renderListBody pads single digits to the index width: `> 12` vs `>  5`.
expect_cursor() {
  frame_has "$1" "^> +${2}[[:space:]]" "cursor is on row $2"
}

run_drive() {
  command -v tmux >/dev/null 2>&1 || {
    printf 'tmux is required for --drive\n' >&2
    exit 2
  }
  # A PID suffix keeps parallel runs and a leftover demo session from
  # colliding; the EXIT trap still tears it down on a failure path.
  local session="codex-auth-selection-demo-$$"
  tmux_session="$session"
  local frames="$demo_home/frames"
  mkdir -p "$frames"

  local runner="$demo_home/run-live.sh"
  {
    printf '#!/bin/sh\n'
    printf "export HOME='%s' CODEX_HOME='%s'\n" "$demo_home" "$demo_home"
    printf "exec '%s' list --live --skip-api\n" "$cli"
  } > "$runner"
  chmod +x "$runner"

  tmux new-session -d -s "$session" -x 118 -y 22 "$runner"

  # The 0.25s capture delay is deliberately shorter than a human glance: if
  # the cursor rendered one frame behind the key state, these frames would
  # show it. The burst steps paste several keys as one chunk to stress the
  # input-batch path the same way a fast typist or a paste does.
  capture() { # capture <name> [seconds]
    sleep "${2:-0.25}"
    tmux capture-pane -p -t "$session" > "$frames/$1.txt"
  }
  send() { tmux send-keys -t "$session" "$1"; }

  capture 00-initial
  send k
  capture 01-single-k
  send j
  capture 02-single-j
  send kkkkj
  capture 03-burst-five-keys 0.4
  send kkkk
  capture 04-burst-onto-eta 0.4
  send Enter
  capture 05-rail-on-cursor-row
  send j
  capture 06-rail-highlight-down
  send k
  capture 07-rail-highlight-up
  send Escape
  capture 08-rail-closed-cursor-kept 0.4
  # Regression: a fast Esc+Arrow must close the rail and scroll, not read as
  # Esc+Esc and quit. Enter reopens the rail first so the second key is
  # visible; one send-keys call lands both inside the same escape window.
  send Enter
  capture 08b-rail-reopened
  tmux send-keys -t "$session" Escape Down
  sleep 0.5
  if ! tmux has-session -t "$session" 2>/dev/null; then
    esc_arrow_failed=1
  fi
  capture 09-esc-arrow-still-live 0.2
  send q
  sleep 0.6
  if tmux has-session -t "$session" 2>/dev/null; then
    quit_failed=1
  fi
  tmux kill-session -t "$session" 2>/dev/null || true

  local frame
  for frame in "$frames"/*.txt; do
    printf '\n===== %s =====\n' "$(basename "$frame" .txt)"
    cat "$frame"
  done
}

run_assertions() {
  printf '\n=== assertions ===\n'
  # The cursor opens on the active account row (zeta, 12): `>` covers `*`.
  frame_has 00-initial '^> +12[[:space:]]' 'cursor opens on the active account row'
  frame_count 00-initial '^>' 1 'exactly one cursor marker' 'cursor markers'
  frame_count 00-initial '#\*' 0 'no "#*" header text' 'header fragments'
  # Single keys: k moves up one row and the * active marker reappears on zeta.
  expect_cursor 01-single-k 11
  frame_has 01-single-k '^\* +12[[:space:]]' 'active marker reappears once the cursor moves off zeta'
  frame_count 01-single-k '^>' 1 'no doubled cursor after a single key' 'cursor markers'
  expect_cursor 02-single-j 12
  # Burst: five pasted keys (4 up, 1 down) land on row 9 (iota-a).
  expect_cursor 03-burst-five-keys 9
  frame_count 03-burst-five-keys '^>' 1 'burst keeps exactly one cursor' 'cursor markers'
  frame_has 03-burst-five-keys '^\* +12[[:space:]]' 'burst did not move the active marker'
  # Four more ups land on row 5 (eta, 2 cards).
  expect_cursor 04-burst-onto-eta 5
  # Enter opens the rail under the cursor row: the row `>` yields to the rail's
  # own credit cursor (cursor_anchored), so only the `*` marker is checked.
  frame_has 05-rail-on-cursor-row '^      RESETS' 'rail anchored on the cursor row'
  frame_has 05-rail-on-cursor-row '^\* +12[[:space:]]' 'active marker untouched by the rail'
  frame_has 05-rail-on-cursor-row 'RESETS[^0-9]*2 available' 'rail shows the eta card list'
  # Inside the rail only the credit highlight moves; card lines indent 6.
  frame_has 06-rail-highlight-down '^      > Later card' 'rail j moved the credit highlight'
  frame_count 06-rail-highlight-down '^>' 0 'row cursor hidden while the rail is open' 'cursor markers'
  frame_has 07-rail-highlight-up '^      > Workspace reset' 'rail k moved it back'
  # Esc closes the rail and the row cursor survives.
  frame_has 08-rail-closed-cursor-kept '^> +5[[:space:]]' 'row cursor preserved after Esc'
  frame_count 08-rail-closed-cursor-kept '^>' 1 'still exactly one cursor' 'cursor markers'
  if [ "$esc_arrow_failed" = 0 ]; then
    printf 'ok    %-26s %s\n' "esc-arrow" 'Esc+Arrow in one batch closes the rail without quitting'
  else
    printf 'FAIL  %-26s %s\n' "esc-arrow" 'Esc+Arrow in one batch closes the rail without quitting'
    assert_failures=$((assert_failures + 1))
  fi
  frame_has 09-esc-arrow-still-live '^> +5[[:space:]]' 'Esc+Arrow kept the session and the row cursor'
  if [ "$quit_failed" = 0 ]; then
    printf 'ok    %-26s %s\n' "quit" 'q exited the live session'
  else
    printf 'FAIL  %-26s %s\n' "quit" 'q exited the live session'
    assert_failures=$((assert_failures + 1))
  fi

  printf '\n%s\n' "$( [ "$assert_failures" = 0 ] && echo 'all selection assertions passed' || echo "$assert_failures selection assertion(s) failed")"
}

if [ "$drive" = 1 ]; then
  run_drive
elif [ ! -t 0 ] || [ ! -t 1 ]; then
  printf '\nNot a terminal: falling back to --drive (install tmux, or run this script in a terminal).\n'
  run_drive
else
  set +e
  case "$screen" in
    list)   env "HOME=$demo_home" "CODEX_HOME=$demo_home" "$cli" list --live --skip-api ;;
    switch) env "HOME=$demo_home" "CODEX_HOME=$demo_home" "$cli" switch --skip-api ;;
    remove) env "HOME=$demo_home" "CODEX_HOME=$demo_home" "$cli" remove --skip-api ;;
  esac
  set -e
fi

if [ "$assert_frames" = 1 ]; then
  run_assertions
  [ "$assert_failures" = 0 ] || exit 1
fi
if [ "$keep" = 1 ]; then
  printf '\nKept for inspection: %s\n' "$demo_home"
fi
