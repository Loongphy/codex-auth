# Implementation Details (Local-Only)

This document describes how `codex-auth` stores accounts, synchronizes auth files, and refreshes metadata. The tool never calls external APIs; it reads only local files under `~/.codex` (or `CODEX_HOME`).

## Packaging and Release

- The CLI binary version is defined in `src/version.zig` and must match the npm package version and any release tag version without the leading `v`.
- npm distribution uses a root package plus four platform packages:
  - Root package: `@loongphy/codex-auth`
  - Platform packages:
    - `@loongphy/codex-auth-linux-x64`
    - `@loongphy/codex-auth-darwin-x64`
    - `@loongphy/codex-auth-darwin-arm64`
    - `@loongphy/codex-auth-win32-x64`
- The root npm package exposes the `codex-auth` command and depends on platform packages through `optionalDependencies`.
- Each platform package declares `os` and `cpu`, so npm installs only the matching binary package for the current OS/CPU.
- Branch and pull request validation runs live in `.github/workflows/ci.yml` and execute the native `build-test` matrix on Ubuntu, macOS, and Windows runners.
- Tag pushes matching `v*` use `.github/workflows/release.yml` to create GitHub Release assets and publish npm packages automatically.
- npm publishing uses Trusted Publishing from GitHub Actions, so the publish job in `.github/workflows/release.yml` must run on a GitHub-hosted runner with `id-token: write`.
- `.github/workflows/release.yml` uses `actions/setup-node@v4` with Node 24 for the npm packaging and publish steps so the bundled npm CLI supports Trusted Publishing.
- npm provenance validation requires the package `repository.url` metadata to match the GitHub repository URL exactly (`https://github.com/Loongphy/codex-auth`), including letter case.
- Stable tags such as `v0.1.3` publish to npm dist-tag `latest`.
- Prerelease tags such as `v0.2.0-rc.1` publish to npm dist-tag `next`.
- GitHub Release assets and npm packages currently target Linux x64, macOS x64, macOS ARM64, and Windows x64.

## File Layout

- `~/.codex/auth.json`
- `~/.codex/accounts/registry.json`
- `~/.codex/accounts/<account_id_b64>.auth.json`
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

- If `registry.json` is empty and `~/.codex/auth.json` exists, the tool auto-imports it into `accounts/<account_id_b64>.auth.json`.
- If the registry is empty and there is no `auth.json`, `list` shows no accounts; use `codex-auth login` or `codex-auth import`.
- `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`.

## Account Identity

ChatGPT auth uses `chatgpt:<email>#<plan>` as the unique key for an account.
API key auth uses `apikey:<fingerprint>`.

- Emails are normalized to lowercase.
- ChatGPT auth requires both `email` and `https://api.openai.com/auth.chatgpt_plan_type`; if the plan is missing, the tool panics.
- API key auth stores only a stable fingerprint in the registry identity key.
- The auth file name is `base64url(account_id)` (URL-safe, no padding).

## Auth Parsing

`auth.json` is parsed as follows:

- If `OPENAI_API_KEY` is present, the account is treated as API-key auth (`auth_mode = apikey`) and a fingerprint is derived from the key.
- Otherwise it looks for `tokens.id_token`, decodes the JWT, and reads the `email` claim and `https://api.openai.com/auth.chatgpt_plan_type`.
- For ChatGPT auth, missing plan is a fatal error. If email is missing, the account is not imported/synced.

## Import Behavior

- `codex-auth import <path>` auto-detects the path type:
  - file path: imports one auth/config file.
  - directory path: batch imports config files from that directory.
- Directory import scans only direct child files with a `.json` suffix (non-recursive), imports valid auth files, and skips invalid/malformed entries.
- Only `import` can set account `alias` (via `--alias` on single-file import).
- For directory import, `--alias` is ignored.
- Non-import flows (`login`, auto-import on empty registry, and sync-created accounts) leave `alias` empty.

## Sync Behavior (Token Refresh Safety)

Each command (`list`, `switch`, `remove`) runs `syncActiveAccountFromAuth` before doing its main work. This is the mechanism that prevents stale refresh tokens when `auth.json` is updated by Codex.

The sync flow is:

1. Read `~/.codex/auth.json` and parse email/plan/auth mode.
2. Build the current account identity key (`email + plan` for ChatGPT auth, fingerprint for API-key auth).
3. If an identity-key match is found:
   - Set that account as active.
   - Overwrite `accounts/<account_id_b64>.auth.json` with the current `auth.json` if content differs.
4. If no identity-key match is found:
   - Create a **new** account record for that identity.
   - Import the current `auth.json` into `accounts/<account_id_b64>.auth.json`.

If `auth.json` has no email, sync is skipped.

Important limits:

- There is no background sync. Tokens are updated only when you run `codex-auth`.
- Matching is strictly by account identity key; there is no fallback to an “active” heuristic.

## Switching Accounts

`switch` supports two modes:

- Interactive: `codex-auth switch`
- Non-interactive: `codex-auth switch <selector>`

For non-interactive switching, the target account is matched case-insensitively against alias, account id, email, `email#plan`, and `apikey:<fingerprint>`.
If multiple accounts match, interactive selection is shown.

When switching:

1. `auth.json` is backed up if its contents would change.
2. The selected account’s `accounts/<account_id_b64>.auth.json` is copied to `~/.codex/auth.json`.
3. The registry’s `active_account_id` is updated.

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
- The `EMAIL` cell uses `(alias)email` when an alias is set for that account.
- The switch/remove UI shows `EMAIL`, `PLAN`, `5H`, `WEEKLY`, `LAST`.
- Usage limit cells show remaining percent plus reset time: `NN% (HH:MM)` for same-day resets, or `NN% (HH:MM on D Mon)` when the reset is on a different day.
- `LAST ACTIVITY` is derived from `last_usage_at` and rendered as a relative time like `Now` or `2m ago`.
- `PLAN` comes from the auth claim when available, and falls back to the last usage snapshot's `plan_type` (e.g. `free`, `plus`, `team`).
