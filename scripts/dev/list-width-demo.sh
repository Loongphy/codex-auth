#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

zig build

demo_home="$(mktemp -d)"
cleanup() {
  rm -rf "$demo_home"
}
trap cleanup EXIT

mkdir -p "$demo_home/accounts"
cat > "$demo_home/accounts/registry.json" <<'JSON'
{
  "schema_version": 4,
  "active_account_key": "user-1::account-1",
  "previous_active_account_key": null,
  "active_account_activated_at_ms": null,
  "interval_seconds": 60,
  "accounts": [
    {
      "account_key": "user-1::account-1",
      "chatgpt_account_id": "account-1",
      "chatgpt_user_id": "user-1",
      "email": "very-long-account-name@example.com",
      "alias": "very-long-account-name",
      "account_name": null,
      "plan": "pro",
      "auth_mode": "chatgpt",
      "created_at": 1,
      "last_used_at": null,
      "last_usage_at": null,
      "last_usage": {
        "primary": { "used_percent": 0, "window_minutes": 300, "resets_at": 4102444800 },
        "secondary": { "used_percent": 42, "window_minutes": 10080, "resets_at": 4103049600 },
        "credits": null,
        "reset_credits": null,
        "plan_type": "pro"
      }
    },
    {
      "account_key": "user-2::account-2",
      "chatgpt_account_id": "account-2",
      "chatgpt_user_id": "user-2",
      "email": "work-main@example.com",
      "alias": "work-main",
      "account_name": null,
      "plan": "pro",
      "auth_mode": "chatgpt",
      "created_at": 2,
      "last_used_at": null,
      "last_usage_at": null,
      "last_usage": {
        "primary": { "used_percent": 69, "window_minutes": 300, "resets_at": 4102444800 },
        "secondary": { "used_percent": 58, "window_minutes": 10080, "resets_at": 4103049600 },
        "credits": { "has_credits": true, "unlimited": true, "balance": null },
        "reset_credits": 3,
        "plan_type": "pro"
      }
    }
  ]
}
JSON

run_list() {
  CODEX_HOME="$demo_home" ./zig-out/bin/codex-auth list --skip-api
}

if [ ! -t 1 ]; then
  run_list
  exit 0
fi

printf 'Drag the terminal wider or narrower. Press Ctrl-C to stop.\n'
sleep 1

while true; do
  printf '\033[2J\033[H'
  printf 'width: %s columns (Ctrl-C to stop)\n\n' "$(tput cols 2>/dev/null || echo '?')"
  run_list
  sleep 0.2
done
