# Implementation Details (Local-Only)

This document describes how `codex-auth` stores accounts, synchronizes auth files, and refreshes metadata. The tool never calls external APIs; it reads only local files under `~/.codex` (or `CODEX_HOME`).

## File Layout

- `~/.codex/auth.json`
- `~/.codex/accounts/registry.json`
- `~/.codex/accounts/<email_b64>.auth.json`
- `~/.codex/accounts/auth.json.bak.<timestamp>`
- `~/.codex/accounts/registry.json.bak.<timestamp>`
- `~/.codex/sessions/...`

`codex-auth` resolves `codex_home` in this order:

1. `CODEX_HOME` (when set and non-empty)
2. `HOME/.codex`
3. `USERPROFILE/.codex` (Windows fallback)
4. `HOMEDRIVE + HOMEPATH + "/.codex"` (Windows fallback)

## Testing Conventions (BDD Style on std.testing)

- The project keeps using Zig native tests (`zig build test`) for CI and local checks.
- BDD scenarios are expressed in Zig `test` blocks with descriptive names like:
  - `Scenario: Given ... when ... then ...`
- Reusable Given/When/Then setup logic should live in test-only helper/context code under `src/tests/` (for example `*_bdd_test.zig` plus helper modules).
- Existing unit-style tests remain valid; BDD-style tests should prioritize behavior flows and branches that are not already covered.

## First Run and Empty Registry

- If `registry.json` is empty and `~/.codex/auth.json` exists, the tool auto-imports it into `accounts/<email_b64>.auth.json`.
- If the registry is empty and there is no `auth.json`, `list` shows no accounts; use `codex-auth add` or `codex-auth import`.

## Account Identity (Email-Only)

The email is the unique key for an account.

- Emails are normalized to lowercase.
- The auth file name is `base64url(email)` (URL-safe, no padding).

## Auth Parsing

`auth.json` is parsed as follows:

- If `OPENAI_API_KEY` is present, the account is treated as API-key auth (`auth_mode = apikey`).
- Otherwise it looks for `tokens.id_token`, decodes the JWT, and reads the `email` claim and `https://api.openai.com/auth.chatgpt_plan_type`.
- If plan is missing, it remains blank in the registry. If email is missing, the account is not imported/synced.

## Import Behavior

- `codex-auth import <path>` auto-detects the path type:
  - file path: imports one auth/config file.
  - directory path: batch imports config files from that directory.
- Directory import scans only direct child files with a `.json` suffix (non-recursive), imports valid auth files, and skips invalid/malformed entries.
- Only `import` can set account `name` (via `--name` on single-file import).
- For directory import, `--name` is ignored.
- Non-import flows (`add`, auto-import on empty registry, and sync-created accounts) leave `name` empty.

## Sync Behavior (Token Refresh Safety)

Each command (`list`, `switch`, `remove`) runs `syncActiveAccountFromAuth` before doing its main work. This is the mechanism that prevents stale refresh tokens when `auth.json` is updated by Codex.

The sync flow is:

1. Read `~/.codex/auth.json` and parse email/plan/auth mode.
2. Match by **email only** against the registry.
3. If an email match is found:
   - Set that account as active.
   - Overwrite `accounts/<email_b64>.auth.json` with the current `auth.json` if content differs.
4. If no email match is found:
   - Create a **new** account record for that email.
   - Import the current `auth.json` into `accounts/<email_b64>.auth.json`.

If `auth.json` has no email, sync is skipped.

Important limits:

- There is no background sync. Tokens are updated only when you run `codex-auth`.
- Matching is strictly by email; no fallback to an alternate key or “active” heuristic.

## Switching Accounts

When switching:

1. `auth.json` is backed up if its contents would change.
2. The selected account’s `accounts/<email_b64>.auth.json` is copied to `~/.codex/auth.json`.
3. The registry’s `active_email` is updated.

## Backups

- `auth.json` backups are created only when the contents change.
- `registry.json` backups are created only when the contents change.
- Both are stored under `~/.codex/accounts/` and capped at the most recent 5 files.

## Usage and Rate Limits

Usage data is read from the newest `~/.codex/sessions/**/rollout-*.jsonl` file only.

- The scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- Rate limits are mapped by `window_minutes`: `300` → 5h, `10080` → weekly (fallback to primary/secondary).
- If `resets_at` is in the past, the UI shows `100% -`.
- `last_usage_at` stores the last time a snapshot was observed.
- `list` and `switch` trigger a one-time scan of the newest rollout file for the active account.

Latest rollout `.jsonl` rate limit record shape (from an `event_msg` + `token_count` line):

```json
{
  "timestamp": "2025-05-07T17:24:21.123Z",
  "type": "event_msg",
  "payload": {
    "type": "token_count",
    "info": {
      "total_token_usage": { "total_tokens": 1234, "input_tokens": 900, "output_tokens": 334, "cached_input_tokens": 0 },
      "last_token_usage":  { "total_tokens": 200,  "input_tokens": 150, "output_tokens": 50,  "cached_input_tokens": 0 },
      "model_context_window": 128000
    },
    "rate_limits": {
      "primary":   { "used_percent": 60.0, "window_minutes": 300, "resets_at": 1735689600 },
      "secondary": { "used_percent": 20.0, "window_minutes": 10080, "resets_at": 1736294400 },
      "credits":   { "has_credits": true, "unlimited": false, "balance": "12.34" },
      "plan_type": "pro"
    }
  }
}
```

## Output Notes

- Default list table columns: `EMAIL`, `PLAN`, `5H USAGE`, `WEEKLY`, `LAST ACTIVITY`.
- The `EMAIL` cell uses `(name)email` when a name is set for that account.
- The switch/remove UI shows `EMAIL`, `PLAN`, `5H`, `WEEKLY`, `LAST`.
- Usage limit cells show remaining percent plus reset time: `NN% (HH:MM)` for same-day resets, or `NN% (HH:MM on D Mon)` when the reset is on a different day.
- `LAST ACTIVITY` is derived from `last_usage_at` and rendered as a relative time like `Now` or `2m ago`.
- `PLAN` comes from the auth claim when available, and falls back to the last usage snapshot's `plan_type` (e.g. `free`, `plus`, `team`).
