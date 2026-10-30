#!/usr/bin/env bash
# Interactive demo of the `list --live` reset credits rail, running the real CLI
# against an isolated CODEX_HOME and the mock backend in tests/fake_curl.zig.
# No network, no real account, no credit is ever consumed.
#
#   scripts/dev/reset-live-demo.sh                     drive the rail yourself
#   scripts/dev/reset-live-demo.sh --drive             scripted tmux session, frames printed
#   scripts/dev/reset-live-demo.sh --assert            same session, asserted as a smoke test
#   scripts/dev/reset-live-demo.sh --scenario http500  make the redeem fail
#   scripts/dev/reset-live-demo.sh --keep              keep the CODEX_HOME for inspection
#
# Scenarios: ok, already_redeemed, no_credit, nothing_to_reset, unknown_code,
# http500, timeout, resolve_failed.
#
# The scenario applies to every account. For a mixed session, drop
# consume-<account_id>.json (e.g. consume-account-ok.json) into the fixtures
# dir instead: a per-account fixture beats the scenario, and fixtures are
# re-read on every request, so edits take effect without a restart.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

scenario="ok"
drive=0
assert_frames=0
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario)
      scenario="${2:-}"
      [ -n "$scenario" ] || { printf '--scenario needs a value\n' >&2; exit 2; }
      shift 2
      ;;
    --drive) drive=1; shift ;;
    --assert) drive=1; assert_frames=1; shift ;;
    --keep) keep=1; shift ;;
    -h | --help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

zig build
zig build test-helpers

demo_home="$(mktemp -d)"
if [ "$keep" = 0 ]; then
  cleanup() { rm -rf "$demo_home"; }
  trap cleanup EXIT
fi

# shellcheck source=scripts/dev/lib/seed-codex-home.sh
source "$repo_root/scripts/dev/lib/seed-codex-home.sh"
seed_codex_home "$demo_home"

fixtures="$demo_home/fixtures"
cli="$repo_root/zig-out/bin/codex-auth"

# The mock shadows the real curl only inside this demo's PATH.
demo_env=(
  "HOME=$demo_home"
  "CODEX_HOME=$demo_home"
  "CODEX_AUTH_FAKE_CURL_DIR=$fixtures"
  "CODEX_AUTH_FAKE_CURL_SCENARIO=$scenario"
  "PATH=$repo_root/zig-out/bin:$PATH"
)

cat <<INFO
Isolated CODEX_HOME : $demo_home
Mock backend        : zig-out/bin/curl (fixtures in $fixtures)
Consume scenario    : $scenario
Request log         : $fixtures/requests.log
Mixed outcomes      : drop consume-<account_id>.json into the fixtures dir; live-reloaded

Demo accounts: ok@ (2 cards), undated@ (no expiry), empty@ (no cards),
spent@ (card already consumed), apikey@ (cannot redeem),
shared@ team-a/team-b (grouped row), dup-one@ / dup-two@ (ambiguous query).

Keys in list --live:
  j / k      move the account-row cursor while the rail is closed
  Enter      open the reset credits rail for a row with available credits
  j / k      move the credit highlight while the rail is open
  Up / Down  move the credit highlight while the rail is open, scroll otherwise
  Enter      arm the highlighted credit; Enter again redeems it
  Esc / q    close the rail, or quit when it is closed
INFO

print_log() {
  printf '\n=== consume requests the CLI sent ===\n'
  if [ -s "$fixtures/requests.log" ]; then
    cat "$fixtures/requests.log"
  else
    printf '(none: no redeem was confirmed)\n'
  fi
}

# --assert turns the scripted session into a smoke test of the real rail: every
# check below reads a frame the real renderer produced.
assert_failures=0

frame_has() { # frame_has <frame> <needle> <what it proves>
  local frame="$demo_home/frames/$1.txt"
  if [ -f "$frame" ] && grep -qF -- "$2" "$frame"; then
    printf 'ok    %-32s %s\n' "$1" "$3"
  else
    printf 'FAIL  %-32s %s (expected: %s)\n' "$1" "$3" "$2"
    assert_failures=$((assert_failures + 1))
  fi
}

frame_lacks() { # frame_lacks <frame> <needle> <what it proves>
  local frame="$demo_home/frames/$1.txt"
  if [ -f "$frame" ] && ! grep -qF -- "$2" "$frame"; then
    printf 'ok    %-32s %s\n' "$1" "$3"
  else
    printf 'FAIL  %-32s %s (unexpected: %s)\n' "$1" "$3" "$2"
    assert_failures=$((assert_failures + 1))
  fi
}

run_assertions() {
  printf '\n=== assertions ===\n'
  frame_lacks 01-enter-empty-no-rail 'Available' 'Enter on a zero-credit row does not open a rail'
  frame_has 01-enter-empty-no-rail 'Enter credits' 'the closed rail keeps the account-list footer'
  frame_has 02-rail-on-two-card-account 'RESET CREDITS · 2 available' 'Enter opens the rail on the two-card row'
  frame_has 02-rail-on-two-card-account '> Full reset (Weekly + 5 hr)' 'the first card starts highlighted'
  frame_has 02-rail-on-two-card-account 'Esc back' 'the open rail replaces the account-list footer'
  frame_has 03-second-credit-highlighted '> Later card' 'Down moved the credit highlight'
  frame_has 04-first-credit-highlighted '> Full reset (Weekly + 5 hr)' 'Up moved it back'
  frame_has 04b-j-second-credit '> Later card' 'j matches Down on the credit list'
  frame_has 04c-k-first-credit '> Full reset (Weekly + 5 hr)' 'k matches Up on the credit list'
  frame_has 05-armed-confirm-hint 'Enter again to use' 'the first Enter armed the credit and drew the hint'
  frame_has 06-redeemed 'reset credit used' 'the second Enter redeemed it'
  frame_has 06-redeemed 'RESET CREDITS · 0 available' 'the consumed card left the rail'
  frame_lacks 06-redeemed 'no available reset credits' 'the empty rail adds no refresh placeholder'
  frame_lacks 06-redeemed 'codex-auth list --api' 'the empty rail adds no refresh command'
  frame_has 07-after-immediate-refresh '96%' 'the immediate refresh shows the reset usage'
  frame_lacks 08-rail-closed 'Available' 'Esc closed the rail'
  frame_has 08-rail-closed 'Enter credits' 'the account-list footer comes back after Esc'

  local posts
  posts=$(grep -c 'POST .*rate-limit-reset-credits/consume' "$fixtures/requests.log" 2>/dev/null || true)
  if [ "$posts" = "1" ]; then
    printf 'ok    %-32s %s\n' "requests.log" 'exactly one consume POST reached the backend'
  else
    printf 'FAIL  %-32s %s (found %s)\n' "requests.log" 'exactly one consume POST reached the backend' "${posts:-0}"
    assert_failures=$((assert_failures + 1))
  fi
  if grep -qE 'Bearer|access-' "$fixtures/requests.log" 2>/dev/null; then
    printf 'FAIL  %-32s %s\n' "requests.log" 'the request log leaked a credential'
    assert_failures=$((assert_failures + 1))
  else
    printf 'ok    %-32s %s\n' "requests.log" 'no credential in the request log'
  fi

  printf '\n%s\n' "$( [ "$assert_failures" = 0 ] && echo 'all rail assertions passed' || echo "$assert_failures rail assertion(s) failed")"
}

run_drive() {
  command -v tmux >/dev/null 2>&1 || {
    printf 'tmux is required for --drive\n' >&2
    exit 2
  }
  local session="codex-auth-reset-demo"
  local frames="$demo_home/frames"
  mkdir -p "$frames"
  tmux kill-session -t "$session" 2>/dev/null || true

  # A runner script keeps the environment out of tmux's command line, so no
  # quoting has to survive two shells.
  local runner="$demo_home/run-live.sh"
  {
    printf '#!/bin/sh\n'
    local entry
    for entry in "${demo_env[@]}"; do
      printf "export %s='%s'\n" "${entry%%=*}" "${entry#*=}"
    done
    printf "exec '%s' list --live\n" "$cli"
  } > "$runner"
  chmod +x "$runner"

  # 22 rows keeps the rail and its anchor row inside one viewport.
  tmux new-session -d -s "$session" -x 118 -y 22 "$runner"

  capture() { # capture <name> [seconds]
    sleep "${2:-0.8}"
    tmux capture-pane -p -t "$session" > "$frames/$1.txt"
  }
  send() { tmux send-keys -t "$session" "$1"; }

  capture 00-table
  # The cursor opens on the active account `ok@`, which has two cards. A detour
  # to `empty@` proves that Enter on a zero-credit row does not open a rail.
  send 'k'
  send 'Enter'
  capture 01-enter-empty-no-rail
  send 'j'
  send 'Enter'
  capture 02-rail-on-two-card-account
  send 'Down'
  capture 03-second-credit-highlighted
  send 'Up'
  capture 04-first-credit-highlighted
  send 'j'
  capture 04b-j-second-credit
  send 'k'
  capture 04c-k-first-credit
  send 'Enter'
  capture 05-armed-confirm-hint
  send 'Enter'
  capture 06-redeemed
  capture 07-after-immediate-refresh 3.0
  send 'Escape'
  capture 08-rail-closed
  send 'q'
  sleep 0.6
  tmux kill-session -t "$session" 2>/dev/null || true

  local frame
  for frame in "$frames"/*.txt; do
    printf '\n===== %s =====\n' "$(basename "$frame" .txt)"
    cat "$frame"
  done
}

if [ "$drive" = 1 ]; then
  run_drive
elif [ ! -t 0 ] || [ ! -t 1 ]; then
  printf '\nNot a terminal: falling back to --drive (install tmux, or run this script in a terminal).\n'
  run_drive
else
  set +e
  env "${demo_env[@]}" "$cli" list --live
  set -e
fi

print_log
if [ "$assert_frames" = 1 ]; then
  run_assertions
  [ "$assert_failures" = 0 ] || exit 1
fi
if [ "$keep" = 1 ]; then
  printf '\nKept for inspection: %s\n' "$demo_home"
fi
