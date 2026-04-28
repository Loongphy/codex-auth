# Implementation Details

This document is the implementation index for `codex-auth`. Command-specific behavior lives in [docs/commands/README.md](./commands/README.md).

## Related Documents

- Command behavior: [docs/commands/README.md](./commands/README.md)
- API refresh and endpoint rules: [docs/api.md](./api.md)
- Background auto-switching: [docs/auto-switch.md](./auto-switch.md)
- File permissions: [docs/permissions.md](./permissions.md)
- Schema migration: [docs/schema-migration.md](./schema-migration.md)
- Test organization: [docs/tests.md](./tests.md)
- Release and CI: [docs/release.md](./release.md)

## Runtime State

`codex-auth` stores local state under the resolved Codex home. The resolution order is:

1. `CODEX_HOME` when it is set to a non-empty existing directory
2. `HOME/.codex`
3. `USERPROFILE/.codex` on Windows

Managed files:

- `<codex_home>/auth.json`
- `<codex_home>/accounts/registry.json`
- `<codex_home>/accounts/<account file key>.auth.json`
- `<codex_home>/accounts/auth.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/accounts/registry.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/sessions/...`

## Registry Compatibility

- `registry.json.schema_version` is the on-disk migration gate.
- `schema_version = 4` is the current layout with record-keyed snapshots, active-account activation timestamps, per-account local rollout dedupe, and default auto-switch thresholds reset to `1`.
- `version = 2` registries using `active_email` and email-keyed snapshots are migrated to the current schema.
- Current-layout files that still use the top-level `version = 3` key are rewritten to `schema_version = 4`.
- Loading a supported older schema performs the migration in memory and rewrites `registry.json` in the current format.
- Loading a newer `schema_version` is rejected with `UnsupportedRegistryVersion`.
- Saving always rewrites `registry.json` into the current schema `4` field set.

See [docs/schema-migration.md](./schema-migration.md) for versioning policy and migration rules.

## Account Identity

`codex-auth` separates the user identity from the ChatGPT workspace/account context.

- `tokens.account_id` is stored as `chatgpt_account_id` and is used for API calls.
- `chatgpt_user_id` is read from JWT auth claims, falling back to `user_id`.
- The local unique key is `record_key = chatgpt_user_id + "::" + chatgpt_account_id`.
- `account_key` stores this local `record_key`.
- Snapshot filenames are derived from `record_key`; filename-unsafe values are base64url-encoded.
- Email is normalized to lowercase and used for display/grouping, not identity.

## Auth Parsing

If `OPENAI_API_KEY` is present, the account is treated as API-key auth. Otherwise, ChatGPT auth requires:

- `tokens.access_token`
- `tokens.account_id`
- `tokens.id_token`
- JWT `https://api.openai.com/auth.chatgpt_account_id`
- JWT user identity from `chatgpt_user_id` or `user_id`

If account identity fields are missing or mismatched, import/login fails. Existing-registry foreground and background sync skip unsyncable auth files and continue with registry state already on disk.

## Active Auth Sync

Foreground account commands sync `auth.json` before their main work when the current auth file is parseable.

The sync flow is:

1. Read `~/.codex/auth.json`.
2. Parse email, plan, auth mode, `chatgpt_user_id`, and `chatgpt_account_id`.
3. Match by `record_key`.
4. Update the matching account and active key, or create a new account record when no match exists.
5. Rewrite the managed account snapshot when contents changed.

The empty-registry auto-import path still requires a parseable auth file. Once a registry exists, malformed or incomplete `auth.json` is skipped rather than deleting stored accounts.

## Backups and Cleanup

- `auth.json` backups are created only when contents change.
- `registry.json` backups are created only when contents change.
- Backups are stored under `~/.codex/accounts/` with local-time names.
- Same-second collisions get a `.N` suffix.
- The newest five managed backups are retained.
- `codex-auth clean` is whitelist-based for the current schema and affects only `~/.codex/accounts/`.

Command behavior for cleanup lives in [docs/commands/clean.md](./commands/clean.md).

## Local Usage Data

When API usage refresh is disabled, local usage refresh reads Codex rollout files under `~/.codex/sessions/**/rollout-*.jsonl`.

- The newest rollout file by `mtime` is scanned.
- The scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- The last parseable `rate_limits` object in that file is used.
- Rollout events older than the current account activation time are ignored.
- Each account stores its own last consumed rollout signature.
- Rate limits map `window_minutes = 300` to 5h and `window_minutes = 10080` to weekly.
- Past reset timestamps render as `100%`.

API-backed refresh details live in [docs/api.md](./api.md). Background watcher refresh details live in [docs/auto-switch.md](./auto-switch.md).

## Display Model

- Human-readable account displays group records by email.
- Group headers are not selectable; child account rows are selectable.
- Alias labels take precedence for child rows.
- Duplicate workspace-style plan labels may use stable numbered labels.
- `PLAN` comes from the auth claim when available, then falls back to usage snapshot plan data.
- Usage cells show remaining percentage plus reset time when reset data is known.
- `LAST ACTIVITY` is rendered as relative time from `last_usage_at`.

Command-specific display behavior lives in the relevant file under [docs/commands/](./commands/).
