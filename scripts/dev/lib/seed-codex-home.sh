# Shared seeding for the reset-credit demos. Not executable on its own; source it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/seed-codex-home.sh"
#   seed_codex_home "$demo_home"
#
# Creates an isolated CODEX_HOME that needs no real account and no network:
#
#   <home>/accounts/registry.json     schema v4 registry with the demo accounts
#   <home>/accounts/<key>.auth.json   one auth snapshot per account
#   <home>/fixtures/*.json            responses for the mock backend in
#                                     tests/fake_curl.zig (built as zig-out/bin/curl)
#
# Then run the CLI with:
#
#   HOME=<home> CODEX_HOME=<home> \
#   CODEX_AUTH_FAKE_CURL_DIR=<home>/fixtures \
#   PATH="<repo>/zig-out/bin:$PATH" \
#   codex-auth list --live

demo_b64url() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

# demo_card <id> <expires_at|null> <title|null> <status>
demo_card() {
  local expires="null" title="null"
  [ "$2" != "null" ] && expires="\"$2\""
  [ "$3" != "null" ] && title="\"$3\""
  printf '{ "id": "%s", "status": "%s", "expires_at": %s, "title": %s }' "$1" "$4" "$expires" "$title"
}

_demo_accounts=""
_demo_created=0

# _demo_account <user> <account_id> <email> <alias> <plan> <5h_percent>
#               <weekly_percent> <available_count> <cards-json> <auth-kind>
_demo_account() {
  local user="$1" account="$2" email="$3" alias="$4" plan="$5"
  local primary="$6" weekly="$7" count="$8" cards="$9" auth_kind="${10}"
  local key="$user::$account"
  _demo_created=$((_demo_created + 1))

  local auth_path="$demo_home/accounts/$(printf '%s' "$key" | demo_b64url).auth.json"
  if [ "$auth_kind" = "apikey" ]; then
    printf '{"OPENAI_API_KEY":"sk-demo-key"}\n' > "$auth_path"
  else
    local header payload
    header=$(printf '%s' '{"alg":"none","typ":"JWT"}' | demo_b64url)
    payload=$(printf '%s' "{\"email\":\"$email\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"$account\",\"chatgpt_user_id\":\"$user\",\"user_id\":\"$user\",\"chatgpt_plan_type\":\"$plan\"}}" | demo_b64url)
    printf '{"tokens":{"access_token":"access-%s","account_id":"%s","id_token":"%s.%s.sig"}}\n' \
      "$account" "$account" "$header" "$payload" > "$auth_path"
  fi

  local usage='null'
  if [ "$auth_kind" != "apikey" ]; then
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
  fi

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
      "auth_mode": "$auth_kind",
      "created_at": $_demo_created,
      "last_used_at": null,
      "last_usage_at": null,
      "last_usage": $usage
    }
JSON
)
  if [ -n "$_demo_accounts" ]; then
    _demo_accounts="$_demo_accounts,"$'\n'"$entry"
  else
    _demo_accounts="$entry"
  fi

  # Mock backend responses for this account. The `after-consume-*` fixtures are
  # what the CLI sees once a redeem succeeded, so the live table and the rail
  # visibly change without editing anything. A consume takes exactly one card:
  # the usage count drops by one, and the fake curl flips that card's status to
  # "consumed" in the credit list dynamically (per the request body's
  # credit_id), so any redemption order leaves the remaining cards intact.
  local remaining_count=0
  if [ "$count" -gt 0 ]; then
    remaining_count=$((count - 1))
  fi
  if [ "$auth_kind" != "apikey" ]; then
    printf '{"plan_type":"%s","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":18000,"reset_at":4102444800},"secondary_window":{"used_percent":%s,"limit_window_seconds":604800,"reset_at":4103049600}},"rate_limit_reset_credits":{"available_count":%s}}\n' \
      "$plan" "$primary" "$weekly" "$count" > "$demo_home/fixtures/usage-$account.json"
    printf '{"credits":%s}\n' "$cards" > "$demo_home/fixtures/credits-$account.json"
    printf '{"plan_type":"%s","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":18000,"reset_at":4102444800},"secondary_window":{"used_percent":2,"limit_window_seconds":604800,"reset_at":4103049600}},"rate_limit_reset_credits":{"available_count":%s}}\n' \
      "$plan" "$remaining_count" > "$demo_home/fixtures/after-consume-usage-$account.json"
  fi
}

# seed_codex_home <CODEX_HOME>
seed_codex_home() {
  demo_home="$1"
  mkdir -p "$demo_home/accounts" "$demo_home/fixtures"
  _demo_accounts=""
  _demo_created=0

  # The account the demos redeem on: two available cards, one expiring sooner.
  _demo_account user-ok account-ok ok@example.com ok plus 92 61 2 \
    "[$(demo_card credit-soon 2026-11-01T00:00:00Z "Full reset (Weekly + 5 hr)" available), $(demo_card credit-later 2027-01-01T00:00:00Z "Later card" available)]" \
    chatgpt
  # The soonest card is dated, the next one is not: the rail renders `-` for it
  # and `reset` reports `1 left (no expiry)` after redeeming the dated one.
  _demo_account user-undated account-undated undated@example.com undated pro 40 20 2 \
    "[$(demo_card credit-undated-soon 2026-11-01T00:00:00Z "Dated card" available), $(demo_card credit-undated null null available)]" \
    chatgpt
  # No cards at all: Enter on this row does not open the rail.
  _demo_account user-empty account-empty empty@example.com empty plus 10 5 0 "[]" chatgpt
  # A card the backend already reports as consumed is filtered out of the rail.
  _demo_account user-spent account-spent spent@example.com spent plus 88 70 0 \
    "[$(demo_card credit-spent 2026-11-01T00:00:00Z "Already used card" consumed)]" \
    chatgpt
  # Two accounts sharing one email render as a group, which is what the rail
  # cursor-to-row mapping has to get right.
  _demo_account user-g1 account-g1 shared@example.com team-a business 55 33 1 \
    "[$(demo_card credit-g1 2026-12-01T00:00:00Z "Workspace reset" available)]" \
    chatgpt
  _demo_account user-g2 account-g2 shared@example.com team-b business 71 44 1 \
    "[$(demo_card credit-g2 2026-12-15T00:00:00Z "Workspace reset" available)]" \
    chatgpt
  # One query matching two accounts: `reset dup` must refuse to guess.
  _demo_account user-dup1 account-dup1 dup-one@example.com dup-one plus 30 30 1 \
    "[$(demo_card credit-dup1 2026-11-05T00:00:00Z "Full reset (Weekly + 5 hr)" available)]" \
    chatgpt
  _demo_account user-dup2 account-dup2 dup-two@example.com dup-two plus 31 31 1 \
    "[$(demo_card credit-dup2 2026-11-06T00:00:00Z "Full reset (Weekly + 5 hr)" available)]" \
    chatgpt
  # An API-key snapshot has no stored usage snapshot, so `reset` stops at the
  # missing-credit check. If it did have a card, the consume step would report
  # MissingAuth; selection-demo.sh seeds that shape for its API-key accounts.
  _demo_account user-apikey account-apikey apikey@example.com apikey plus 0 0 1 \
    "[$(demo_card credit-apikey 2026-11-01T00:00:00Z "Full reset (Weekly + 5 hr)" available)]" \
    apikey

  cat > "$demo_home/accounts/registry.json" <<JSON
{
  "schema_version": 4,
  "active_account_key": "user-ok::account-ok",
  "previous_active_account_key": null,
  "active_account_activated_at_ms": null,
  "interval_seconds": 60,
  "accounts": [
$_demo_accounts
  ]
}
JSON
}
