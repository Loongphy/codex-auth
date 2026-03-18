# Implementation Details

This document describes how `codex-auth` stores accounts, synchronizes auth files, and refreshes metadata. The tool reads and writes local files under `~/.codex`, and for ChatGPT-auth usage refresh it can call the ChatGPT usage endpoint for the current active account.

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
- Pull request preview npm packages live in `.github/workflows/preview-release.yml`. The workflow cross-builds the four platform binaries on Ubuntu, stages the same five npm package directories used by the release pipeline, rewrites the staged root package `optionalDependencies` to the deterministic `pkg.pr.new` platform package URLs for the PR head SHA, and then publishes all five preview packages in a single `pkg.pr.new` command so the PR install command keeps the current platform-selective npm install behavior.
- The staged preview root package also gets a `codexAuthPreviewLabel` field like `pr-6 b6bfcf5`; the root CLI wrapper uses that field so `codex-auth --version` prints `codex-auth <version> (preview pr-6 b6bfcf5)` for preview installs only.
- `.github/workflows/preview-release.yml` uses `actions/setup-node@v6` with `node-version: lts/*` so preview publishing tracks the latest Node LTS line automatically.
- `pkg.pr.new` preview publishing requires the pkg.pr.new GitHub App to be installed on the repository before the workflow can publish previews or comment on PRs.
- Tag pushes matching `v*` use `.github/workflows/release.yml` to create GitHub Release assets and publish npm packages automatically.
- npm publishing uses Trusted Publishing from GitHub Actions, so the publish job in `.github/workflows/release.yml` must run on a GitHub-hosted runner with `id-token: write`.
- `.github/workflows/release.yml` uses `actions/setup-node@v6` with Node 24 for the npm packaging and publish steps so the bundled npm CLI supports Trusted Publishing.
- The `setup-node` steps in `.github/workflows/release.yml` explicitly set `package-manager-cache: false` to avoid future automatic npm cache behavior changes in the release pipeline.
- npm provenance validation requires the package `repository.url` metadata to match the GitHub repository URL exactly (`https://github.com/Loongphy/codex-auth`), including letter case.
- Stable tags such as `v0.1.3` publish to npm dist-tag `latest`.
- Prerelease tags such as `v0.2.0-rc.1` publish to npm dist-tag `next`.
- Prerelease tags such as `v0.2.0-rc.1` also create GitHub draft releases marked as prereleases.
- GitHub Release assets and npm packages currently target Linux x64, macOS x64, macOS ARM64, and Windows x64.
- Windows builds include both `codex-auth.exe` and the background helper `codex-auth-auto.exe`; the helper is used only by the managed auto-switch task.

## File Layout

- `~/.codex/auth.json`
- `~/.codex/accounts/registry.json`
- `~/.codex/accounts/<account file key>.auth.json`
- `~/.codex/accounts/auth.json.bak.YYYYMMDD-hhmmss[.N]`
- `~/.codex/accounts/registry.json.bak.YYYYMMDD-hhmmss[.N]`
- `~/.codex/sessions/...`

`codex-auth` resolves `codex_home` from the real user home directory:

1. `HOME/.codex`
2. `USERPROFILE/.codex` (Windows fallback)

## Testing Conventions (BDD Style on std.testing)

- The project keeps using Zig native tests rooted at `src/main.zig`.
- The current `zig build test` step compiles the test binary but does not execute it.
- To run the tests locally, use `zig test src/main.zig -lc`.
- BDD scenarios are expressed in Zig `test` blocks with descriptive names like:
  - `Scenario: Given ... when ... then ...`
- Reusable Given/When/Then setup logic should live in test-only helper/context code under `src/tests/` (for example `*_bdd_test.zig` plus helper modules).
- Existing unit-style tests remain valid; BDD-style tests should prioritize behavior flows and branches that are not already covered.

## First Run and Empty Registry

- If `registry.json` is empty and `~/.codex/auth.json` exists, the tool auto-imports it into `accounts/<account file key>.auth.json`.
- If the registry is empty and there is no `auth.json`, `list` shows no accounts; use `codex-auth login` or `codex-auth import`.
- `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`.

## Registry Compatibility

- `registry.json.schema_version` is the on-disk migration gate.
- The current binary supports all released schemas:
  - `schema_version = 3` is the current layout with record-keyed snapshots, active-account activation timestamps, and per-account local rollout dedupe.
  - `version = 2` legacy registries using `active_email` and email-keyed snapshots are auto-migrated to schema `3`.
- The current binary also accepts current-layout files that still use the legacy top-level key `version = 3`, or still carry the old global `last_attributed_rollout` shape, and rewrites them once to the normalized `schema_version = 3` format.
- Loading a supported older schema performs the migration in memory and then rewrites `registry.json` in the current format.
- Loading a newer `schema_version` is rejected with `UnsupportedRegistryVersion`; older binaries must not silently rewrite newer registry files.
- Saving always rewrites `registry.json` into the current field set with `schema_version = 3`.
- Unknown extra fields are still ignored on load and dropped on save, so additive compatibility is only guaranteed for schemas explicitly supported by the current binary.
- See `docs/schema-migration.md` for the versioning policy and migration rules.

## Account Identity

`codex-auth` now separates the user identity from the ChatGPT workspace/account context.

- `tokens.account_id` is the raw ChatGPT workspace/account context ID used for API calls. In the registry it is stored as `chatgpt_account_id`.
- The JWT claim `https://api.openai.com/auth.chatgpt_account_id` must exist and match `tokens.account_id`.
- `chatgpt_user_id` is read from the JWT auth claims (`chatgpt_user_id`, falling back to `user_id`).
- The local unique key is `record_key = chatgpt_user_id + "::" + chatgpt_account_id`.
- The registry field `account_key` stores this local `record_key`, not the raw ChatGPT workspace/account ID.
- The auth snapshot file key is derived from `record_key`:
  - filename-safe IDs keep the raw `record_key`
  - other IDs are base64url-encoded before writing `accounts/<account file key>.auth.json`
- Email is normalized to lowercase, but it is only a display/grouping field instead of the unique key.

## Auth Parsing

`auth.json` is parsed as follows:

- If `OPENAI_API_KEY` is present, the account is treated as API-key auth (`auth_mode = apikey`).
- Otherwise it requires:
  - `tokens.access_token` for ChatGPT usage API refresh
  - `tokens.account_id`
  - `tokens.id_token`
  - JWT `https://api.openai.com/auth.chatgpt_account_id`
- The CLI decodes the JWT and reads `email`, `chatgpt_account_id`, `chatgpt_user_id` (or fallback `user_id`), and `chatgpt_plan_type`.
- If `account_id` is missing or mismatched between token fields and JWT claims, import/login fails. Existing-registry foreground/background sync treats that auth as unsyncable and skips it.
- If `chatgpt_user_id` is missing, import/login fails. Existing-registry foreground/background sync treats that auth as unsyncable and skips it.
- If plan is missing, it remains blank in the registry. If email is missing, the account is not imported/synced.

## Import Behavior

- `codex-auth import <path>` auto-detects the path type:
  - file path: imports one auth/config file.
  - directory path: batch imports config files from that directory.
- `codex-auth import --purge [<path>]` rebuilds `registry.json` from scratch using the imported auth set for the current binary format.
- During `--purge`, `auto_switch` and `api` configuration are carried forward from an existing `registry.json`; account snapshots, stored usage, active-account activation time, and per-account local rollout dedupe state are cleared and rebuilt from auth files.
- When `--purge` is used without a path, the source defaults to `~/.codex/accounts/` and scans direct child auth files from that directory: current account snapshots (`*.auth.json`) plus `auth.json.bak.*` backups.
- If `~/.codex/accounts/` is missing during `--purge`, it is treated as an empty snapshot set and the command still attempts to import the current `~/.codex/auth.json`.
- `--purge` always tries to import the current `~/.codex/auth.json` last; if it is parseable, that account's `record_key` becomes `active_account_key`.
- When multiple scanned auth files map to the same `record_key`, `--purge` keeps only the newest snapshot for that account before rebuilding `registry.json`.
- `--purge` rebuilds `registry.json` and rewrites imported snapshots into the current `accounts/<account file key>.auth.json` naming/layout for each auth file it can parse successfully.
- Rebuilt `registry.json` account entries are ordered by normalized `email`, then `account_key`.
- `--purge` does not delete old snapshot files or backups, so stale pre-migration snapshot filenames may still remain until cleaned up separately.
- `--purge` is a recovery fallback when a registry cannot be migrated automatically; it is not the normal upgrade path between supported schemas.
- Directory import scans only direct child files with a `.json` suffix (non-recursive), imports valid auth files, and skips invalid/malformed entries.
- Only `import` can set account `alias` (via `--alias` on single-file import).
- For directory import or `--purge` without an explicit file path, `--alias` is ignored.
- Non-import flows (`login`, auto-import on empty registry, and sync-created accounts) leave `alias` empty.

## Sync Behavior (Token Refresh Safety)

Each command (`list`, `switch`, `remove`) runs `syncActiveAccountFromAuth` before doing its main work. This is the mechanism that prevents stale refresh tokens when `auth.json` is updated by Codex.

The sync flow is:

1. Read `~/.codex/auth.json` and parse email/plan/auth mode.
2. Match by **record_key** (`chatgpt_user_id + "::" + chatgpt_account_id`) against the registry.
3. If a `record_key` match is found:
   - Set that account as active.
   - Update the stored email/plan/auth mode from the current auth.
   - Update the stored `chatgpt_account_id` and `chatgpt_user_id` fields from the current auth.
   - Overwrite `accounts/<account file key>.auth.json` with the current `auth.json` if content differs.
4. If no `record_key` match is found:
   - Create a **new** account record for that auth snapshot.
   - Import the current `auth.json` into `accounts/<account file key>.auth.json`.

If `auth.json` has no email, no `tokens.account_id`, no `chatgpt_user_id`, or cannot be parsed, existing-registry sync is skipped and the foreground command/daemon continues using the registry state already on disk. The empty-registry auto-import path still requires a parseable auth file.

Important limits:

- Foreground commands sync `auth.json` strictly by `record_key`; there is no alternate key or “active” heuristic.
- When background auto-switching is enabled, a background worker keeps checking rollout usage and can switch accounts without a foreground `codex-auth` command.

## Switching Accounts

`switch` supports two modes:

- Interactive: `codex-auth switch`
- Non-interactive: `codex-auth switch <query>`

For non-interactive switching, the target account is matched case-insensitively by:

- alias fragment
- email fragment

If multiple accounts match, interactive selection is shown. In the switch picker, `q` quits without switching.

When switching:

1. `auth.json` is backed up if its contents would change.
2. The selected account’s `accounts/<account file key>.auth.json` is copied to `~/.codex/auth.json`.
3. The registry’s `active_account_key` is updated to that account’s `record_key`.

The switch command refreshes the current active account's usage once before rendering account choices, so the picker does not show stale data for the currently selected account. It does not refresh the newly selected account after the switch completes.

## Background Auto Switch

`config auto` supports the user-facing commands:

- `codex-auth config auto enable`
- `codex-auth config auto disable`
- `codex-auth config auto [--5h <percent>] [--weekly <percent>]`

The feature is off by default and persisted in `registry.json` under a top-level `auto_switch` block.
`status` prints the current `Auto Switch: ON/OFF` state, service runtime, thresholds, and whether usage API calls are enabled.
`help` prints the current `Auto Switch: ON/OFF` state plus the configured thresholds.
When `api.usage = true`, `help`, `status`, and `list` also print a warning that API-based usage refresh may trigger OpenAI account restrictions or suspension, and that `codex-auth config api disable` switches to safer but less accurate local-only usage reading.

Usage API refresh mode is persisted separately under a top-level `api` block:

- `api.usage = true` (default): API-only mode, call the ChatGPT usage API only and do not fall back to local rollout files
- `api.usage = false`: local-only mode, read `~/.codex/sessions/**/rollout-*.jsonl` only, make no usage API calls

The related configuration command is:

- `codex-auth config api enable`
- `codex-auth config api disable`

The threshold configuration is also persisted in `registry.json`:

- `auto_switch.threshold_5h_percent` (default `10`)
- `auto_switch.threshold_weekly_percent` (default `5`)

The configuration command can update either threshold independently or both in one command.
If background auto-switching is already active, threshold changes do not require reinstalling or restarting the managed service. On Linux/WSL and Windows the next scheduled run reads the updated registry; on macOS the running daemon reads it on the next poll cycle.

When enabled:

1. A background worker checks usage continuously or on a fixed schedule, depending on platform.
2. It refreshes usage for the current active account:
   - in API mode, only from the ChatGPT usage API
   - in local-only mode, only from the newest rollout file
   In local-only mode, a rollout event is attributed only if its `event_timestamp_ms` is at or after the current active account's activation time. Each account also remembers its own last consumed local rollout signature so repeated `list`/daemon runs do not reconsume the same local event.
3. If active-account remaining quota is below either threshold, it switches to the best alternative account without foreground CLI output:
   - `5h` remaining `< auto_switch.threshold_5h_percent` (default `10%`)
   - `weekly` remaining `< auto_switch.threshold_weekly_percent` (default `5%`)
   - on Linux/WSL, the timer-triggered service writes a user-service journal line with the source and destination emails when an automatic switch happens
4. Candidate scoring is reset-aware:
   - if `resets_at <= now`, that window is treated as fully reset (`100%`)
   - if both 5h and weekly are known, the candidate score is the lower remaining value
   - if only one window is known, that window is the score
   - if an account has no usage snapshot at all, it is treated as a fresh account with `100%` remaining

Service bootstrap is platform-specific:

- Linux/WSL: `systemd --user` oneshot service plus timer, running once per minute
- macOS: `LaunchAgent`
- Windows: user scheduled task running once per minute and launching `codex-auth-auto.exe` directly with no batch wrapper

Service install paths are resolved from the real user home directory.
The generated Linux/macOS service definition stamps the current `codex-auth` version. On macOS and Windows, and on Linux/WSL when a `systemd --user` session is available, any successful foreground `codex-auth` command except `help`, `version`, `status`, and `daemon` reconciles the managed service after command execution. Unsupported platforms or Linux/WSL environments without user systemd skip this reconciliation entirely:

- if `auto_switch.enabled = false`, it stops and uninstalls any managed background service left behind by an earlier enablement
- if `auto_switch.enabled = true` and the managed timer/service definition is missing, stopped, or still points at an older service definition/version, it reinstalls the platform service and starts it with the current binary
- On Linux/WSL, `config auto enable` also requires a working `systemd --user` session; if it is unavailable, the command fails before changing `registry.json`.

## Backups

- `auth.json` backups are created only when the contents change.
- `registry.json` backups are created only when the contents change.
- Both are stored under `~/.codex/accounts/` using the local-time filename format `*.bak.YYYYMMDD-hhmmss` (with `.N` added only on same-second collisions) and capped at the most recent 5 files.
- If local-time conversion is unavailable, backup filenames fall back to `*.bak.<unix-seconds>`.
- `codex-auth clean` is whitelist-based for the current schema and only affects `~/.codex/accounts/`: it keeps only live snapshot files referenced by the registry and deletes other stale entries under `accounts/`.
- If `accounts/registry.json` is missing, `codex-auth clean` still prunes backup files but skips stale snapshot deletion so recovery snapshots remain available for `import --purge` or manual repair.


## Usage and Rate Limits

Usage refresh is active-account-only and depends on `api.usage`:

1. If `api.usage = true`, try only the ChatGPT usage API with the current active `~/.codex/auth.json`.
2. If `api.usage = false`, read only the newest `~/.codex/sessions/**/rollout-*.jsonl` file by `mtime`.

- ChatGPT API refresh sends `Authorization: Bearer <tokens.access_token>` and `ChatGPT-Account-Id: <chatgpt_account_id>` to `https://chatgpt.com/backend-api/wham/usage`.
- API refresh only updates the current active account. Other accounts keep their stored historical snapshots until they become active.
- API refresh writes a new snapshot only when the fetched snapshot differs from the stored one; unchanged API responses do not rewrite `registry.json`.
- In API-only mode, API failures do not overwrite the stored usage snapshot and do not fall back to local rollout files.
- The rollout scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- The rollout scanner reads only the newest rollout file. Within that file, it uses the last `token_count` event whose `rate_limits` payload is a parseable object.
- If the newest rollout file has no usable `rate_limits` payload (for example `rate_limits: null` on every `token_count` event), refresh does not overwrite the account's existing stored usage snapshot.
- Local-session refresh never uses a global rollout watermark. Instead it compares the rollout event timestamp against the current active account's activation time; rollout events older than that activation point are treated as stale and are not reassigned to the new active account.
- Each account stores its own last consumed local rollout signature `(path, event_timestamp_ms)`, so repeated local refreshes for the same account do not reapply the same rollout event.
- Rate limits are mapped by `window_minutes`: `300` → 5h, `10080` → weekly (fallback to primary/secondary).
- If `resets_at` is in the past, the UI shows `100%`.
- `last_usage_at` stores the last time a newly observed snapshot was written; identical API refreshes leave it unchanged.
- `list`, `switch`, and the auto-switch background worker use the same active-account refresh path.
- `switch` refreshes only the current active account before the selection/switch step; it does not refresh the newly selected account after the switch completes.
- API refresh does not mutate any local rollout attribution state.
- The rollout files still do not expose a stable account identity, so local-session ownership remains activation-window based rather than identity based.

Current registry/account field roles:

- `account_key`: local `record_key`, used for registry identity, snapshot filenames, switching, and `active_account_key`
- `chatgpt_account_id`: raw ChatGPT workspace/account context ID from `tokens.account_id`, used for usage API requests
- `chatgpt_user_id`: user identity component from the JWT, used to build `record_key`

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
