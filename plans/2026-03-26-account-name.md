---
name: account-name
description: Finalized account-name sync behavior for accounts/check parsing, registry persistence, refresh policy, and list/switch/remove display rules
---

# Account Name Sync

This document records the shipped behavior for ChatGPT `account_name` sync and display.

## Final Result

- `registry.AccountRecord` stores `account_name: ?[]u8`.
- `registry.json` stays on schema `3`.
- `api` config is split into:
  - `api.usage`
  - `api.account`
- Missing `api.account` or `api.usage` fields are backfilled from the sibling flag on load.
- `account_name` is persisted as either a string or `null`.

## Real Account Identity Format

- The runtime account identity is `account_key = "<chatgpt_user_id>::<chatgpt_account_id>"`.
- Real keys look like `user-opaque-id::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf`.
- `registry.json` stores the plain `account_key`.
- Snapshot files under `~/.codex/accounts` use a URL-safe base64 encoding of `account_key`, then append `.auth.json`.
- Encoding is required because `account_key` contains `:` and is not always filename-safe.

## Accounts Check Payload

- Endpoint:
  - `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
- Request headers:
  - `Authorization: Bearer <token>`
  - `ChatGPT-Account-Id: <account_id>` when present
  - `User-Agent: codex-auth`
- Parsed fields:
  - `accounts.<non-default>.account.account_id`
  - `accounts.<non-default>.account.name`
- Ignored fields:
  - `accounts.default`
  - `account_ordering`
  - all other payload fields
- Real payload shape uses the `chatgpt_account_id` as the `accounts` map key.
- `default` is only the web default-selection entry and is not treated as a real account row.
- `account_ordering` may contain only real account IDs and is currently ignored by parsing.
- `name: null` and `name: ""` are both normalized to `account_name = null`.

## Refresh Policy

- Refresh is disabled when `api.account == false`.
- Refresh requires a usable auth context with:
  - `access_token`
  - `chatgpt_user_id`
  - `chatgpt_account_id`
- Refresh scope is one `chatgpt_user_id`.
- One `chatgpt_user_id` represents one user and may contain multiple workspace `chatgpt_account_id` values.
- This means a plus/free workspace can trigger refresh for Team workspaces only when they belong to the same `chatgpt_user_id`.
- A refresh is eligible only when the scoped records satisfy all of these:
  - there is more than one scoped account
  - at least one scoped Team account exists
  - at least one scoped Team account still has a missing `account_name`
- Refresh timing:
  - `login`: inline refresh after auth is available
  - single-file `import`: inline refresh from the imported auth
  - `list`: inline refresh for the active auth
  - `switch`: activate and save first, then spawn a background account-name-only refresh for the newly active scope
  - `daemon`: when auto-switch is enabled, each daemon cycle also checks the active scope and refreshes missing Team names in the background watcher
- Background switch refresh is skipped when `api.account == false`.
- Background switch refresh re-loads the latest registry after `accounts/check` returns, then applies only the refreshed `account_name` result before saving.
- No account-name refresh runs during:
  - directory import
  - `import --purge`

## Apply Rules

- Returned entries are matched by `chatgpt_account_id`.
- Matching scoped records receive the returned `account_name`.
- Scoped Team records missing from the response are cleared to `null`.
- Scoped non-Team records with no stored `account_name` stay unchanged when no entry matches.
- Scoped non-Team records with a stale stored `account_name` are cleared if the response does not include them.
- Records outside the refresh scope are left unchanged.
- Request failures and parse failures are non-fatal:
  - the command still succeeds
  - stored metadata is left as-is

## Display Rules

- `list` and `switch` share the same display-row builder.
- Rows are grouped by `email` within the rendered subset, not the full registry.
- Singleton rule:
  - if the rendered subset contains exactly one account for an email, the row is singleton
  - singleton rows display the email directly
- Grouped rule:
  - the email becomes a header row
  - child rows use the preferred label builder
- Preferred label precedence for grouped child rows:
  - alias + account name => `alias (account_name)`
  - alias only => `alias`
  - account name only => `account_name`
  - neither => plan fallback such as `team`, `plus`, or `team #2`
- `remove` keeps email context even for singleton rows:
  - plain singleton email stays `email`
  - singleton alias/name rows are rendered as `email / preferred-label`

## Validation Coverage

- Parser coverage:
  - ignores `default`
  - accepts UUID-style account keys in the `accounts` object
  - keeps multiple non-default accounts
  - normalizes personal-account `name: null`
  - normalizes personal-account `name: ""`
  - treats malformed HTML as a non-fatal failure
- Registry coverage:
  - old registries load with `account_name = null`
  - `account_name` round-trips for `null` and string values
  - `api.account` round-trips and backfills correctly
  - same-user scoped updates apply to related Team records
- Display coverage:
  - singleton rows keep email labels
  - singleton/grouped behavior is decided from the rendered subset
  - grouped child rows keep alias/account-name precedence
  - remove labels preserve email context for singleton alias/name rows
- Command validation:
  - `zig build run -- list`
