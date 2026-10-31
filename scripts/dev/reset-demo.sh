#!/usr/bin/env bash
# Runs the documented `codex-auth reset` outcomes against an isolated CODEX_HOME
# and the mock backend in tests/fake_curl.zig, so the real CLI output can be read
# on any platform without a real account, a network call, or a consumed credit.
#
#   scripts/dev/reset-demo.sh            every documented outcome, with exit codes
#   scripts/dev/reset-demo.sh --dump     the data shapes: registry, raw backend
#                                        response, and parsed `list --json`
#   scripts/dev/reset-demo.sh --keep     leave the temporary CODEX_HOME in place
#
# The interactive rail is demoed by scripts/dev/reset-live-demo.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

mode="cases"
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dump) mode="dump"; shift ;;
    --keep) keep=1; shift ;;
    -h | --help)
      sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
scenario="ok"

run_cli() { # run_cli <args...>
  HOME="$demo_home" \
    CODEX_HOME="$demo_home" \
    CODEX_AUTH_FAKE_CURL_DIR="$fixtures" \
    CODEX_AUTH_FAKE_CURL_SCENARIO="$scenario" \
    PATH="$repo_root/zig-out/bin:$PATH" \
    ./zig-out/bin/codex-auth "$@"
}

run_case() { # run_case <scenario> <label> <args...>
  local scenario="$1"
  local label="$2"
  shift 2
  local stderr_file="$demo_home/stderr"
  rm -f "$stderr_file"
  printf '\n=== %s ===\n' "$label"
  printf '$ codex-auth'
  printf ' %q' "$@"
  printf '\n'
  if [ "$scenario" != "ok" ]; then
    printf '(mock scenario: %s)\n' "$scenario"
  fi
  local output code
  set +e
  output=$(run_cli "$@" 2>"$stderr_file")
  code=$?
  set -e
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
  if [ -s "$stderr_file" ]; then
    printf 'stderr:\n'
    cat "$stderr_file"
  fi
  printf 'exit: %s\n' "$code"
}

printf 'Isolated CODEX_HOME: %s\n' "$demo_home"
printf 'Mock backend: zig-out/bin/curl with fixtures in %s\n' "$fixtures"
printf 'Nothing below touches the network or a real account.\n'

if [ "$mode" = "dump" ]; then
  printf '\n=== 1. what the demo stores in the registry (accounts[0]) ===\n'
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["accounts"][0], indent=2))' \
    "$demo_home/accounts/registry.json"
  printf '\n=== 2. what the backend returns for that account ===\n'
  printf -- '--- GET wham/usage (fixtures/usage-account-ok.json) ---\n'
  python3 -m json.tool "$fixtures/usage-account-ok.json"
  printf -- '--- GET wham/rate-limit-reset-credits (fixtures/credits-account-ok.json) ---\n'
  python3 -m json.tool "$fixtures/credits-account-ok.json"
  printf -- '--- POST wham/rate-limit-reset-credits/consume (scenario ok) ---\n'
  printf '{"code":"reset","windows_reset":1}\n'
  printf '\n=== 3. what codex-auth derives from it (list --json) ===\n'
  run_cli list --json | python3 -m json.tool
  printf '\n=== 4. the table the same data renders as ===\n'
  run_cli list --skip-api
  exit 0
fi

run_case ok "success: soonest-expiring card is redeemed, the rest are summarized" reset ok@example.com
run_case already_redeemed "success: backend says already_redeemed, still exit 0" reset ok@example.com
run_case no_credit "failure: the card is gone (no_credit)" reset ok@example.com
run_case nothing_to_reset "failure: usage does not need a reset (nothing_to_reset)" reset ok@example.com
run_case unknown_code "failure: backend sends a code the CLI does not know" reset ok@example.com
run_case http500 "failure: backend returns HTTP 500" reset ok@example.com
run_case timeout "failure: the request times out (curl exit 28)" reset ok@example.com
run_case resolve_failed "failure: the request cannot reach the host (curl exit 6)" reset ok@example.com
run_case ok "failure: no available reset credits" reset empty@example.com
run_case ok "failure: the only card is already consumed" reset spent@example.com
run_case ok "failure: API-key account cannot redeem (no stored credits)" reset apikey@example.com
run_case ok "failure: selector matches nothing" reset nobody@example.com
run_case ok "failure: selector matches several accounts" reset dup
run_case ok "success: the next card carries no expiry" reset undated@example.com
run_case ok "success: that was the last card" reset dup-one@example.com
run_case ok "usage error: missing selector" reset
run_case ok "usage error: a leading dash is a flag, not the previous account" reset -
run_case ok "help topic" reset --help
run_case ok "the matching table column, for comparison" list --skip-api

printf '\n=== consume requests the CLI actually sent ===\n'
if [ -s "$fixtures/requests.log" ]; then
  cat "$fixtures/requests.log"
else
  printf '(none)\n'
fi
