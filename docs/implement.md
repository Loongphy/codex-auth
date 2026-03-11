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
- `~/.codex/accounts/<account_id>.auth.json`
- `~/.codex/accounts/auth.json.bak.<timestamp>`
- `~/.codex/accounts/registry.json.bak.<timestamp>`
- `~/.codex/backups/v2/<timestamp>/...`
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

- If `registry.json` is empty and `~/.codex/auth.json` exists, the tool auto-imports it into `accounts/<account_id>.auth.json`.
- If the registry is empty and there is no `auth.json`, `list` shows no accounts; use `codex-auth login` or `codex-auth import`.
- `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`.

## Schema Migration

Schema versioning, migration history, command behavior, and local migration testing are maintained in the dedicated Chinese document:

- [`docs/schema-migration.md`](./schema-migration.md)

That file is the canonical reference for:

- formal schema definitions (`v2`, `v3`, ...)
- adjacent migrator chain rules (`vN -> vN+1`)
- automatic migration entry points and output
- `codex-auth migrate`
- local development workflow for testing `v2 -> v3`

## Account Identity

`account_id` is the unique key for a ChatGPT account snapshot.

- `account_id` is read from `tokens.account_id`.
- The JWT claim `https://api.openai.com/auth.chatgpt_account_id` must also exist and match `tokens.account_id`.
- The auth snapshot file name is the raw `account_id`, stored as `accounts/<account_id>.auth.json`.
- Email is still normalized to lowercase, but it is now a display/grouping field instead of the unique key.
- Older email-key registries are migrated by re-reading legacy auth snapshots and extracting `account_id`.

## Auth Parsing

`auth.json` is parsed as follows:

- If `OPENAI_API_KEY` is present, the account is treated as API-key auth (`auth_mode = apikey`).
- Otherwise it requires:
  - `tokens.account_id`
  - `tokens.id_token`
  - JWT `https://api.openai.com/auth.chatgpt_account_id`
- The CLI decodes the JWT and reads `email`, `chatgpt_account_id`, and `chatgpt_plan_type`.
- If `account_id` is missing or mismatched between token fields and JWT claims, import/login/sync fails.
- If plan is missing, it remains blank in the registry. If email is missing, the account is not imported/synced.

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
2. Match by **account_id** against the registry.
3. If an `account_id` match is found:
   - Set that account as active.
   - Update the stored email/plan/auth mode from the current auth.
   - Overwrite `accounts/<account_id>.auth.json` with the current `auth.json` if content differs.
4. If no `account_id` match is found:
   - Create a **new** account record for that auth snapshot.
   - Import the current `auth.json` into `accounts/<account_id>.auth.json`.

If `auth.json` has no email or `account_id`, sync fails.

Important limits:

- Foreground commands sync `auth.json` strictly by `account_id`; there is no alternate key or “active” heuristic.
- When background auto-switching is enabled, a daemon keeps polling rollout usage and can switch accounts without a foreground `codex-auth` command.

## Switching Accounts

`switch` supports two modes:

- Interactive: `codex-auth switch`
- Non-interactive: `codex-auth switch <query>`

For non-interactive switching, the target account is matched case-insensitively by:

- alias fragment
- email fragment

If multiple accounts match, interactive selection is shown.

When switching:

1. `auth.json` is backed up if its contents would change.
2. The selected account’s `accounts/<account_id>.auth.json` is copied to `~/.codex/auth.json`.
3. The registry’s `active_account_id` is updated.

## Background Auto Switch

`auto` supports three user-facing commands:

- `codex-auth auto enable`
- `codex-auth auto disable`
- `codex-auth auto status`

The feature is off by default and persisted in `registry.json` under a top-level `auto_switch` block.
`help` prints the current `Auto Switch: ON/OFF` state.

When enabled:

1. A background daemon runs continuously.
2. It refreshes usage from the newest rollout file and assigns that snapshot to the current active account.
   The daemon also remembers the last attributed rollout `(path, mtime)` and will not reassign an unchanged rollout after an automatic switch.
3. If active-account remaining quota is below either threshold, it silently switches to the best alternative account:
   - `5h` remaining `< 10%`
   - `weekly` remaining `< 5%`
4. Candidate scoring is reset-aware:
   - if `resets_at <= now`, that window is treated as fully reset (`100%`)
   - if both 5h and weekly are known, the candidate score is the lower remaining value
   - if only one window is known, that window is the score
   - if an account has no usage snapshot at all, it is treated as a fresh account with `100%` remaining

Service bootstrap is platform-specific:

- Linux/WSL: `systemd --user`
- macOS: `LaunchAgent`
- Windows: user scheduled task

Service install paths are resolved from the real user home directory, not from `CODEX_HOME`.
The generated service definition also preserves the `CODEX_HOME` value that was active when `codex-auth auto enable` was run.
The generated service definition also stamps the current `codex-auth` version. Any successful foreground `codex-auth` command except `help`, `version`, and `daemon` reconciles the managed service after command execution:

- if `auto_switch.enabled = false`, it leaves the background service stopped
- if `auto_switch.enabled = true` and the service is missing, stopped, or still points at an older service definition/version, it reinstalls the platform service and starts it with the current binary

## Backups

- `auth.json` backups are created only when the contents change.
- `registry.json` backups are created only when the contents change.
- Both are stored under `~/.codex/accounts/` and capped at the most recent 5 files.
- Schema migration adds a separate whole-directory backup under `~/.codex/backups/v2/<timestamp>`.
- `codex-auth clean` is whitelist-based for the current schema and only affects `~/.codex/accounts/`: it keeps only live snapshot files referenced by the registry and deletes other stale entries under `accounts/`.


## Usage and Rate Limits

Usage data is read from the newest `~/.codex/sessions/**/rollout-*.jsonl` file that still contains a parseable rate-limit snapshot.

- The scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- If the newest rollout file has no usable `rate_limits` payload (for example `rate_limits: null` on every `token_count` event), that file is skipped and the scanner falls back to the most recent rollout that does contain a parseable snapshot.
- Rate limits are mapped by `window_minutes`: `300` → 5h, `10080` → weekly (fallback to primary/secondary).
- If `resets_at` is in the past, the UI shows `100%`.
- `last_usage_at` stores the last time a snapshot was observed.
- `list`, `switch`, and the auto-switch daemon scan the newest rollout file with a parseable snapshot and write that snapshot to the current active account.
- The auto-switch daemon persists the last attributed rollout signature so that the same unchanged rollout is not reassigned immediately after an automatic account switch.
- The rollout files do not expose a stable account identity, so `codex-auth` still cannot infer account ownership beyond the active-account + last-attributed-rollout guard.

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

- Default list table columns: `ACCOUNT`, `PLAN`, `5H USAGE`, `WEEKLY`, `LAST ACTIVITY`.
- Human-readable `list`, `switch`, and `remove` group records by email when the same email owns multiple account snapshots.
- In grouped output:
  - the top-level email line is a header only
  - child rows are the selectable accounts
  - alias takes precedence for the child label
  - otherwise the child label is the plan name (`team`, `plus`, etc.)
  - repeated plans under the same email are rendered as stable numbered labels like `team #1`, `team #2`
- Single-account emails still render as one flat row; when an alias is set, that row shows `(alias)email`.
- The switch/remove UI shows `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST`.
- Usage limit cells show remaining percent plus reset time: `NN% (HH:MM)` for same-day resets, or `NN% (HH:MM on D Mon)` when the reset is on a different day.
- `LAST ACTIVITY` is derived from `last_usage_at` and rendered as a relative time like `Now` or `2m ago`.
- `PLAN` comes from the auth claim when available, and falls back to the last usage snapshot's `plan_type` (e.g. `free`, `plus`, `team`).
