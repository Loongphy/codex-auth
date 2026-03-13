# Schema Migration

This document defines how `codex-auth` versions the on-disk `~/.codex/accounts/registry.json` file.

## Terms

- `app_version` is the CLI release version from `src/version.zig`.
- `schema_version` is the registry file format version stored in `registry.json`.
- `schema_version` is about migration only; it is not the same thing as the CLI release version.

## Current Policy

- `codex-auth` keeps a single `registry.json`; feature state such as `auto_switch` and `api` stays in that file.
- The latest binary supports every released schema. Right now that means:
  - legacy `version = 2`
  - `schema_version = 3`
  - current `schema_version = 4`
- The current binary also accepts current-layout files that still use the old top-level key `version = 3` and rewrites them once to `schema_version = 4`.
- If the binary sees a newer `schema_version` than it understands, it fails with `UnsupportedRegistryVersion` and must not write the file.

## Upgrade Behavior

- User-visible behavior is always “upgrade directly to the latest supported schema”.
- Internally, migrations are implemented as a chain of `Vn -> Vn+1` steps.
- Example: if a future binary supports `schema_version = 4`, a user with `version = 2` is upgraded in memory as `2 -> 3 -> 4`, then the file is rewritten once as schema `4`.
- Users are not expected to install intermediate `codex-auth` versions.

## Released Schemas

- `version = 2`
  - Email-keyed account snapshots
  - `active_email`
  - Email-based account identity
- `schema_version = 3`
  - Account-id-based account snapshots
  - `active_account_id`
  - Current `auto_switch` block
- `schema_version = 4`
  - Account-id-based account snapshots
  - `active_account_id`
  - Current `auto_switch` block
  - Current top-level `api` block

## When To Bump `schema_version`

Bump the schema version whenever the persisted `registry.json` shape or semantics change. That includes:

- Adding, removing, or renaming a persisted field
- Changing a field type
- Changing identity keys such as `active_email` to `active_account_id`
- Changing snapshot filename conventions or any other rule needed to find persisted files
- Reinterpreting an existing field with incompatible semantics

Do not bump the schema version for:

- CLI output changes
- Pure in-memory logic changes
- Help text or documentation changes
- Runtime behavior changes that do not alter persisted registry data

## Migration Rules

- A supported older schema must auto-migrate on load and then rewrite `registry.json` in the current format.
- Supported migrations should preserve account records, active account selection, and account snapshot usability.
- Migration rewrites create the usual `registry.json.bak.*` backup before replacing the file.
- `import --purge` remains a manual recovery path if a registry is corrupted or too old for the current binary, but it is not the normal path between supported schemas.
