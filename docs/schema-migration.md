# Schema Migration

This document defines the `codex-auth` schema versions, migration rules, runtime migration behavior, and the recommended local workflow for testing schema upgrades.

## Core Rule

`codex-auth` uses a monotonically increasing `schema_version` and keeps only adjacent migrators.

- The codebase does not maintain one-off “any old version -> latest” migration paths.
- Instead, it permanently keeps migrators of the form `vN -> vN+1`.
- When the program starts and detects an older registry, it runs the chain in order:
  - `vN -> vN+1`
  - `vN+1 -> vN+2`
  - ...
  - until the latest version

Why this design is used:

- Each migrator stays small and easy to review.
- Shipping a new schema only requires adding one new adjacent migrator.
- The latest binary does not need a growing set of direct old-to-latest branches.

Current latest schema version:

- `v3`

## Formal Schema Definitions

### `v2`

`v2` is the formal legacy layout that identifies accounts by email.

- `registry.json`
  - `version: 2`
  - `active_email`
  - `accounts[].email`
- auth snapshot files
  - `accounts/<base64(email)>.auth.json`

### `v3`

`v3` is the current layout that identifies accounts by `account_id`.

- `registry.json`
  - `version: 3`
  - `active_account_id`
  - `accounts[].account_id`
- auth snapshot files
  - `accounts/<account file key>.auth.json`
  - the file key keeps raw `account_id` only when it is filename-safe; otherwise it uses base64url(`account_id`)

## Migration Entry Points

The following foreground commands automatically check and migrate the schema before their main behavior runs:

- `list`
- `login`
- `import`
- `switch`
- `remove`
- `clean`

Commands that do not trigger migration:

- `help`
- `version`
- `auto enable`
- `auto disable`
- `auto status`
- `daemon`

`daemon` does not trigger migration by itself. It assumes the data directory has already been migrated by a foreground command. This avoids a daemon process stopping the service it is currently running under.

## Migration Output

If a command detects that migration is required, it prints migration progress to `stdout` before the command's normal output.

Example:

```text
Migrating schema: v2 -> v3
Running migration v2 -> v3...
Backing up current data to: ~/.codex/accounts/backups/v2/20260312-063235
Migration complete. Current schema: v3
```

Note: the implementation currently prints Chinese runtime messages. This document describes the intended command semantics rather than enforcing a specific display language.

## The `v2 -> v3` Migrator

The only formal product migrator currently implemented is:

- `v2 -> v3`

It upgrades the email-key model to the `account_id` model.

### Migration Target

From:

- `active_email`
- `accounts[].email`
- `accounts/<base64(email)>.auth.json`

To:

- `active_account_id`
- `accounts[].account_id`
- `accounts/<account file key>.auth.json`

### Two-Phase Execution Model

`v2 -> v3` uses a two-phase migration flow to reduce the risk of destructive partial upgrades.

Execution order:

1. Read the `v2` `registry.json`
2. Scan legacy snapshots in `accounts/<base64(email)>.auth.json`
3. Parse the real `account_id` from each legacy auth file
4. Back up the whole `accounts/` directory to:
   - `~/.codex/accounts/backups/v2/<timestamp>`
5. If `auto_switch.enabled = true` before migration:
   - stop the managed auto-switch service first
6. Copy legacy snapshots to their new names:
   - `accounts/<account file key>.auth.json`
   - old files are not deleted yet
7. Save the new `v3 registry.json`
8. Delete the old legacy files only after the new registry has been written successfully:
   - `accounts/<base64(email)>.auth.json`
9. If auto-switch was enabled before migration:
   - reinstall and re-enable the service using the current binary
10. If one legacy snapshot is malformed, report it, skip just that account, and keep migrating the other valid accounts. Recovery remains possible from the `accounts/backups/v2/<timestamp>` directory.

### Why Two Phases

If migration is interrupted midway, for example by:

- `Ctrl+C`
- a process crash
- WSL shutdown
- a permissions failure
- a full disk

the worst expected state should only be:

- old and new snapshot files coexist

and not:

- old files are already deleted
- the new registry was never written

Under the two-phase model, rerunning any foreground command can complete the remaining work.

## Backup Policy

Schema migration creates a whole-directory backup at:

- `~/.codex/accounts/backups/v2/<timestamp>`

Here `v2` means “this backup was taken before migrating from `v2`”.

Important distinction:

- this migration backup is for rollback across schema upgrades
- it does not replace normal day-to-day file-level backups

Normal file-level backups remain unchanged:

- `~/.codex/accounts/auth.json.bak.<timestamp>`
- `~/.codex/accounts/registry.json.bak.<timestamp>`

## The `clean` Command

`clean` is whitelist-based. It is intended to leave only the current live schema content and remove everything else that does not belong to the current schema.

Command:

- `codex-auth clean`

Behavior:

- scans `~/.codex/accounts/` using a whitelist of allowed current-schema entries
- keeps:
  - `registry.json`
  - `auto-switch.lock`
  - `accounts/<account file key>.auth.json` when that file is referenced by the current `registry.json`
- removes every other entry under `~/.codex/accounts/`
  - including stale snapshot files from older schemas
  - including all `auth.json.bak.*`
  - including all `registry.json.bak.*`
  - including unknown files or directories that do not belong to the current schema

It does not delete:

- anything outside `~/.codex/accounts/`

So `clean` keeps only the live files required by the current schema and removes all other stale entries under `accounts/`. Migration backups under `~/.codex/accounts/backups/` are intentionally left untouched.

## Local Development: Testing `v2 -> v3`

Because foreground commands auto-migrate, running:

```bash
zig build run -- list
```

against your real `~/.codex` will immediately upgrade that home to `v3`. That is not suitable for repeated migration testing.

The recommended workflow is to use a disposable `CODEX_HOME` fixture.

### Recommended Steps

1. Create a temporary directory, for example:

```bash
export CODEX_HOME=/tmp/codex-v2-fixture
```

2. Manually prepare a formal `v2` fixture in that directory:

- `accounts/registry.json`
  - `version: 2`
  - `active_email`
  - `accounts[].email`
- `accounts/<base64(email)>.auth.json`

3. Run:

```bash
zig build run -- list
```

4. Inspect the migrated fixture:

- `registry.json` should now be `version: 3`
- auth snapshots should now be `accounts/<account file key>.auth.json`
- a migration backup should exist under:
  - `accounts/backups/v2/<timestamp>/...`

### Repeatable Testing

Do not repeatedly “downgrade” an already-migrated `v3` directory by hand and keep testing on it.

A better workflow is:

- keep one pristine `v2` fixture
- copy it before each migration test run
- run `list` against the copied fixture

### Development-Only Intermediate States

Local development may create unreleased intermediate states such as:

- shapes that are not formal `v2`
- filenames that were never part of a released schema

Those are not product schemas and should not be part of the formal migration contract.

If you want to validate the real product path, rewrite the fixture back to the formal `v2` shape first, then rerun the migration on that disposable `CODEX_HOME`.
