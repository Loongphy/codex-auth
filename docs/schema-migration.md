# Schema Migration

This document defines how `codex-auth` versions the on-disk `~/.codex/accounts/registry.json` file.

## Terms

- `app_version` is the CLI release version from `src/version.zig`.
- `schema_version` is the registry file format version stored in `registry.json`.
- `schema_version` is about migration only; it is not the same thing as the CLI release version.

## Current Policy

- The current persisted format is `schema_version = 5`.
- The compatibility guarantee for this release is migration from released schema `4` to the final schema `5` format.
- The legacy `version = 2` loader remains available, but it is not the compatibility boundary for this change.
- The current binary accepts current-layout files that still use the old top-level key `version = 3`, or still carry the old global `last_attributed_rollout` shape, and rewrites them to normalized `schema_version = 5`.
- If the binary sees a newer `schema_version` than it understands, it fails with `UnsupportedRegistryVersion` and must not write the file.

## Upgrade Behavior

- User-visible behavior is always “upgrade directly to the latest supported schema”.
- Internally, migrations are implemented as a chain of `Vn -> Vn+1` steps.
- The guaranteed automatic migration is `schema_version = 4 -> schema_version = 5`; older supported layouts are rewritten directly to schema `5`.
- The existing legacy `version = 2` loader also rewrites directly to schema `5`.
- Users are not expected to install intermediate `codex-auth` versions.

## Schema History

- `version = 2`
  - Email-keyed account snapshots
  - `active_email`
  - Email-based account identity
- `schema_version = 3`
  - Record-key-based account snapshots
  - `active_account_key`
  - `active_account_activated_at_ms`
  - Per-account `last_local_rollout`
  - Legacy top-level `api` block, now ignored and omitted on rewrite
  - Per-account `account_key`
  - Each account also stores `chatgpt_account_id` and `chatgpt_user_id`
- `schema_version = 4`
  - Same account layout as schema `3`
  - Live refresh interval stored as top-level `interval_seconds`
  - Older `live.interval_seconds` and removed `auto_switch` blocks are omitted on rewrite
  - Adds top-level `previous_active_account_key` for `codex-auth -` and `codex-auth switch -`
  - Persisted plans use final product semantics rather than backend identifiers
  - Legacy `team` becomes `business`
  - Legacy `business` becomes `enterprise`
  - The same conversion applies to per-account `last_usage.plan_type`
- `schema_version = 5`
  - Stores the access-token expiry timestamp for each account when the token exposes a JWT `exp` claim
  - Stores reset-credit detail records returned by the reset-credit endpoint alongside the available count

## When To Bump `schema_version`

Before bumping `schema_version`, ask the user whether this change should bump the schema. Do not bump it silently.

The rationale behind this policy — including why purely additive fields count as a bump here — is in [Versioning Rationale](#versioning-rationale) below.

Bump the schema version whenever the persisted `registry.json` shape or semantics change. That includes:

- Adding, removing, or renaming a persisted field
- Changing a field type
- Changing identity keys such as `active_email` to `active_account_key`
- Changing snapshot filename conventions or any other rule needed to find persisted files
- Reinterpreting an existing field with incompatible semantics

Do not bump the schema version for:

- CLI output changes
- Pure in-memory logic changes
- Help text or documentation changes
- Runtime behavior changes that do not alter persisted registry data

## Versioning Rationale

The `schema_version` number exists for **old binaries**, not new ones. The decision to bump is not "did the shape change" but "would an older binary behave incorrectly against a file written by this one". In practice:

- **Backward compatibility** (new binary reads old data) is guaranteed by the migration chain above.
- **Forward compatibility** (old binary reads new data) is deliberately **not** attempted: a file with a newer `schema_version` is rejected instead of being interpreted with partial knowledge.

### The rewriting-proxy hazard

`codex-auth` never edits `registry.json` in place. Every mutation (sync, switch, import, migration) loads the whole file and rewrites it wholesale. A binary that does not know a field therefore **strips that field silently** on its next write. This "lossy proxy" behavior is why tolerant readers alone are not enough here, and why the project chooses fail fast: a newer file is refused with `UnsupportedRegistryVersion` rather than read-and-rewritten, because **explicit breakage beats silent data loss** for a tool that manages credentials.

### Why additive fields still bump

General industry practice often lets tolerant readers absorb additive optional fields without a version bump, and that is defensible when the added data is refetchable and old/new versions rarely coexist. This repository takes the stricter side on purpose:

- The rewriting proxy above makes honest forward compatibility impossible.
- `registry.json` holds credential and identity state, where silent degradation is the worst failure mode.
- The migration machinery (auto-migrate plus `registry.json.bak.*` backups) makes a bump cheap and reversible.

### Decision checklist

1. **Old read**: would an older binary misinterpret (not merely miss) the new data? Misinterpretation always requires a bump.
2. **Old write**: if an older binary rewrote the file, what is lost — and does it self-heal (refetchable) or not (source of truth)? Non-healing loss requires a bump; healing-only loss is the judgment call this document resolves toward bumping.
3. **Mixed fleet**: do old and new binaries realistically run against the same file (downgrades, parallel installs)? The more likely, the stronger the case for bumping.

If any test fails, bump. When in doubt, bump: the migration chain keeps the cost near zero.

Version numbers stay a single monotonic integer. File formats do not carry semver; consumers only need to know whether they understand the file, not how much it changed.

## Migration Rules

- A supported older schema must auto-migrate on load and then rewrite `registry.json` in the current format.
- Supported migrations should preserve account records, active account selection, and account snapshot usability.
- Migration rewrites create the usual `registry.json.bak.*` backup before replacing the file.
- `import --purge` remains a manual recovery path if a registry is corrupted or too old for the current binary, but it is not the normal path between supported schemas.
