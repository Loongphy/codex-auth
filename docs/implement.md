# Implementation Details

This document describes how `codex-auth` stores accounts, synchronizes auth files, and refreshes metadata. The tool reads and writes local files under `~/.codex`, and for ChatGPT-auth usage refresh it can call the ChatGPT usage endpoint for the current active account.

## Packaging and Release

- Release automation and CI workflow details live in [docs/release.md](./release.md).
- The CLI binary version is defined in `src/version.zig` and must match the npm package version and any release tag version without the leading `v`.

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
- `codex-auth import --cpa [<path>]` imports flat CPA token JSON:
  - explicit file path: imports one CPA JSON file
  - explicit directory path: batch imports direct child `.json` files from that directory
  - omitted path: defaults to `~/.cli-proxy-api` and scans direct child `.json` files there
- CPA imports convert each source file in memory to the current standard auth snapshot layout before writing `accounts/<account file key>.auth.json`.
- CPA conversion expects the flat fields `id_token`, `access_token`, `refresh_token`, `account_id`, and `last_refresh`; `refresh_token` is required and missing/empty values are skipped as `MissingRefreshToken`.
- CPA imports keep the current report formatting and stream split used by standard imports.
- `--cpa` cannot be combined with `--purge`.
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
- Directory import and purge print a progress preamble like `Scanning <path>...`, then one line per import result, then an `Import Summary: ...` line.
- Single-file import prints one result line:
  - `✓ imported` for a new account
  - `✓ updated` when the target account already exists
  - `✗ skipped` plus a short reason for parse/validation failures
- Single-file import prints a summary only when the file is skipped; the current format is `Import Summary: 0 imported, 1 skipped`.
- Import output is split by stream:
  - `stdout`: scanning lines, `imported`/`updated` lines, and summaries
  - `stderr`: `skipped` lines and alias-ignore warnings
- Import result labels use the input filename with a trailing `.json` or `.auth.json` removed.
- JSON parse failures are rendered as the user-facing reason `MalformedJson`; semantic validation errors keep explicit names such as `MissingEmail` or `MissingChatgptUserId`.
- During `--purge`, duplicate snapshot candidates that lose to a newer snapshot are reported as `skipped` with the reason `SupersededByNewerSnapshot`.
- During `--purge`, if the current `~/.codex/auth.json` is imported last, it is reported as `auth.json (active)` and counted in the purge summary.
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

The detailed runtime, thresholds, service model, and data-source priority rules for auto-switching now live in `docs/auto-switch.md`.

This document keeps only the cross-reference points that matter to the rest of the implementation:

- background config still lives in `registry.json` under top-level `auto_switch` and `api` blocks
- managed services still resolve install paths from the real user home directory
- successful foreground `codex-auth` commands except `help`, `version`, `status`, and `daemon` still reconcile the managed service definition
- Linux/WSL `config auto enable` still requires a working `systemd --user` session

## Backups

- `auth.json` backups are created only when the contents change.
- `registry.json` backups are created only when the contents change.
- Both are stored under `~/.codex/accounts/` using the local-time filename format `*.bak.YYYYMMDD-hhmmss` (with `.N` added only on same-second collisions) and capped at the most recent 5 files.
- If local-time conversion is unavailable, backup filenames fall back to `*.bak.<unix-seconds>`.
- `codex-auth clean` is whitelist-based for the current schema and only affects `~/.codex/accounts/`: it keeps only live snapshot files referenced by the registry and deletes other stale entries under `accounts/`.
- If `accounts/registry.json` is missing, `codex-auth clean` still prunes backup files but skips stale snapshot deletion so recovery snapshots remain available for `import --purge` or manual repair.


## Usage and Rate Limits

Foreground usage refresh is active-account-only and depends on `api.usage`:

1. If `api.usage = true`, foreground refresh tries only the ChatGPT usage API with the current active `~/.codex/auth.json`.
2. If `api.usage = false`, read only the newest `~/.codex/sessions/**/rollout-*.jsonl` file by `mtime`.

- ChatGPT API refresh sends `Authorization: Bearer <tokens.access_token>` and `ChatGPT-Account-Id: <chatgpt_account_id>` to `https://chatgpt.com/backend-api/wham/usage`.
- Foreground API refresh updates only the current active account. During background auto-switch, if the current active account is below threshold and a switch is being considered, the watcher can also refresh candidate ChatGPT accounts from their stored `accounts/<account file key>.auth.json` snapshots before making the final switch decision.
- In watcher mode, repeated candidate API revalidation for the same active account is throttled; the daemon does not re-fetch every candidate on every 1-second loop.
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
- `list` and `switch` use the foreground active-account refresh path.
- The background auto-switch watcher has its own near-real-time refresh strategy; see `docs/auto-switch.md`.
- The free-plan `35%` real-time guard applies only when a real 5h window exists; weekly-only free accounts still switch based on the configured weekly threshold.
- For auto-switch candidate scoring, free accounts that expose only a single weekly (`10080`-minute) window still remain eligible and use that weekly remaining percentage as their candidate score.
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
