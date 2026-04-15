# Implementation Details

This document describes how `codex-auth` stores accounts, synchronizes auth files, and manages local state under `~/.codex`. Outbound API refresh rules, endpoint contracts, and grouped account-name sync examples now live in [docs/api-refresh.md](./api-refresh.md).

## Packaging and Release

- Release automation and CI workflow details live in [docs/release.md](./release.md).
- The CLI binary version is defined in `src/version.zig` and must match the npm package version and any release tag version without the leading `v`.
- Historical GitHub-release installs could place a standalone binary under `~/.local/bin`; this is separate from the npm package path and can shadow newer npm or local-build installs if left on `PATH`.

## File Layout

- `<codex_home>/auth.json`
- `<codex_home>/accounts/registry.json`
- `<codex_home>/accounts/<account file key>.auth.json`
- `<codex_home>/accounts/auth.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/accounts/registry.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/sessions/...`

`codex-auth` resolves `codex_home` in this order:

1. `CODEX_HOME` when it is set to a non-empty existing directory
2. `HOME/.codex`
3. `USERPROFILE/.codex` (Windows fallback)

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
- If `--purge` rebuilds accounts successfully but still has no active account afterward, it activates the first rebuilt account in sorted order and rewrites `~/.codex/auth.json` through the normal switch path, preserving the previous file as `auth.json.bak.*` when the contents changed.
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

Grouped account-name metadata refresh, when needed, now runs in the same foreground pre-selection phase as that usage refresh; see [docs/api-refresh.md](./api-refresh.md).

## Removing Accounts

`remove` now supports three foreground modes:

- Interactive: `codex-auth remove`
- Query-driven: `codex-auth remove <query>`
- Clear-all: `codex-auth remove --all`

For query-driven removal, the target query is matched case-insensitively by:

- alias fragment
- email fragment

If no accounts match, the command prints an error and exits non-zero.
If exactly one account matches, it is removed immediately.
If multiple accounts match in a TTY session, the command prints the matched account labels using the same display grouping as `list` and asks for confirmation with `Confirm delete? [y/N]:`; only `y` or `Y` proceeds.
If multiple accounts match and stdin is not a TTY, the command exits non-zero instead of reading the pipe as confirmation input; the user must refine the query or rerun it interactively.

When an account is removed, `codex-auth` deletes both:

- the account snapshot `accounts/<account file key>.auth.json`
- any parseable `accounts/auth.json.bak.*` backup files whose auth `record_key` matches the removed account

Malformed or non-parseable `auth.json.bak.*` files are left in place for manual cleanup or `codex-auth clean`.

If the removed account was the active one:

- when other accounts still remain, `codex-auth` activates the remaining account with the best current usage score
- if `~/.codex/auth.json` is missing and another account remains, `remove` recreates it from the replacement account snapshot
- `~/.codex/auth.json` is only rewritten or deleted when the current auth file is syncable and can be identified as the removed active account
- when no accounts remain and the current active auth file matches the removed active account, `codex-auth` deletes `~/.codex/auth.json`
- if the current `~/.codex/auth.json` is malformed, unsyncable, or otherwise does not match the removed active account, `remove` leaves that file untouched

For `remove --all`, the command clears all accounts tracked in `registry.json` and deletes any matching managed snapshots/backups. If the current `~/.codex/auth.json` is syncable and its `record_key` matches one of those tracked accounts, `remove --all` deletes it even when `active_account_key` is null or stale. If the current `~/.codex/auth.json` is malformed, unsyncable, or otherwise cannot be identified as one of those tracked accounts, `remove --all` leaves that file untouched.
During remove reconciliation, a dangling `active_account_key` is treated the same as an unset active account so the command can promote a remaining account or finish clearing `~/.codex/auth.json`.

After a successful deletion, stdout prints `Removed N account(s): ...` using the removed account emails in removal order.

When `remove` is run without a query and stdin is not a TTY, the command falls back to the numbered selector and accepts only strict numeric selections like `1 2` or `1,2`; other piped input is rejected.

## Background Auto Switch

The detailed runtime, thresholds, service model, and data-source priority rules for auto-switching now live in `docs/auto-switch.md`.

This document keeps only the cross-reference points that matter to the rest of the implementation:

- background config still lives in `registry.json` under top-level `auto_switch` and `api` blocks
- managed services resolve from the same `codex_home` root as the active CLI process
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

Detailed API-backed refresh behavior now lives in [docs/api-refresh.md](./api-refresh.md). This section keeps only the local-state and rollout rules that interact with the rest of the implementation.

Foreground usage refresh still depends on `api.usage`:

1. If `api.usage = true`, the API contract and timing rules are defined in [docs/api-refresh.md](./api-refresh.md).
2. If `api.usage = false`, read only the newest `~/.codex/sessions/**/rollout-*.jsonl` file by `mtime`.

- Local rollout watcher logs print the actual window lengths from the snapshot first, then the local event timestamp, then the full rollout basename (including the UUID suffix); when the newest event has no usable usage windows the same `[local]` log line also adds `fallback-to-api`.
- The rollout scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- The rollout scanner reads only the newest rollout file. Within that file, it uses the last `token_count` event whose `rate_limits` payload is a parseable object.
- If the newest rollout file has no usable `rate_limits` payload (for example `rate_limits: null` on every `token_count` event), refresh does not overwrite the account's existing stored usage snapshot.
- Local-session refresh never uses a global rollout watermark. Instead it compares the rollout event timestamp against the current active account's activation time; rollout events older than that activation point are treated as stale and are not reassigned to the new active account.
- Each account stores its own last consumed local rollout signature `(path, event_timestamp_ms)`, so repeated local refreshes for the same account do not reapply the same rollout event.
- Rate limits are mapped by `window_minutes`: `300` → 5h, `10080` → weekly (fallback to primary/secondary).
- If `resets_at` is in the past, the UI shows `100%`.
- `last_usage_at` stores the last time a newly observed snapshot was written; identical API refreshes leave it unchanged.
- The background auto-switch watcher has its own near-real-time refresh strategy; see `docs/auto-switch.md`.
- In watcher mode, rollout scanning caches the newest rollout file between bounded full rescans so large `~/.codex/sessions` trees are not fully re-walked on every 1-second loop.
- The free-plan `35%` real-time guard applies only when the 5h trigger comes from an actual 300-minute window or an unlabeled primary window; weekly-only free accounts still switch based on the configured weekly threshold.
- For auto-switch candidate scoring, free accounts that expose only a single weekly (`10080`-minute) window still remain eligible and use that weekly remaining percentage as their candidate score.
- On Linux/WSL, watcher installation/removal now explicitly deletes the old `codex-auth-autoswitch.timer` unit file so legacy minute-timer installs do not continue to fire after migration to the watcher service.
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
- `list` adds a zero-padded leading row number for selectable accounts, such as `01`, `02`.
- Human-readable `list`, `switch`, and `remove` group records by email when the same email owns multiple account snapshots.
- In grouped output:
  - the top-level email line is a header only
  - child rows are the selectable accounts
  - alias takes precedence for the child label
  - otherwise the child label is the human-readable plan name (`Team`, `Plus`, `Pro Lite`, etc.)
  - workspace-style duplicate plans may use stable numbered labels like `Team #1`, `Team #2`
  - non-workspace duplicate plans (`Free`, `Plus`, `Pro`, `Pro Lite`) do not use `#1` / `#2`; they should use another disambiguator such as an account or user suffix
- Single-account emails still render as one flat row; when an alias is set, that row shows `(alias)email`.
- The switch/remove UI shows `ACCOUNT`, `PLAN`, `5H`, `WEEKLY`, `LAST`, and preserves grouped child indentation.
- Usage limit cells show remaining percent plus reset time: `NN% (HH:MM)` for same-day resets, or `NN% (HH:MM on D Mon)` when the reset is on a different day.
- `LAST ACTIVITY` is derived from `last_usage_at` and rendered as a relative time like `Now` or `2m ago`.
- `PLAN` comes from the auth claim when available, and falls back to the last usage snapshot's `plan_type` (for example raw values like `free`, `plus`, `prolite`, `team` are shown as `Free`, `Plus`, `Pro Lite`, `Team`).
