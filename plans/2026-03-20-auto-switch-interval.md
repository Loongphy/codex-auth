---
name: auto-switch-interval
description: Add configurable auto-switch polling intervals plus PR/review execution tracking
---

# Plan

Implement configurable auto-switch polling intervals for `codex-auth`, then drive the branch through the full PR, CI, GitHub review, and `codex review` loops with all progress and findings recorded here.

## Requirements
- Add `codex-auth config auto --interval <integer><s|m|h>`.
- Allow `--interval` to be combined with `--5h` and `--weekly`.
- Keep `enable` and `disable` mutually exclusive with config flags.
- Persist the interval in `registry.json`.
- Bump the registry schema from `3` to `4`.
- Default older registries to `1m` during migration.
- Show the current interval in help and status output.
- Apply the configured interval on Linux/WSL, macOS, and Windows.
- On Windows, warn in English and clamp any interval below `1m` up to `1m`.
- Record implementation progress, CI state, GitHub review threads, and `codex review` findings in this file.
- Remove the temporary `AGENTS.md` execution lock once the task is fully complete.

## Scope
- In: CLI parsing, registry persistence/migration, daemon scheduling, service-definition generation, docs, tests, GitHub PR lifecycle, and review loops.
- Out: unrelated CLI redesigns, non-auto-switch configuration changes, or broader scheduler refactors unrelated to configurable intervals.

## Files and entry points
- `src/cli.zig` for argument parsing and help output
- `src/registry.zig` for persisted config and schema migration
- `src/auto.zig` for status, runtime scheduling, and service definitions
- `src/tests/*.zig` for parser, registry, and scheduling coverage
- `README.md`, `docs/implement.md`, `docs/schema-migration.md`, and `docs/test.md` for docs

## Data model / API changes
- Add `auto_switch.interval_seconds: u32` with default `60`.
- Write `registry.json` as `schema_version = 4`.
- Keep loading support for schema versions `2`, `3`, and `4`.
- Add CLI support for `config auto --interval <integer><s|m|h>`.

## Action items
- [x] Add this plan file and keep implementation aligned with it.
- [x] Add a temporary `AGENTS.md` execution lock pointing at this plan file.
- [x] Extend CLI parsing/help with `--interval`.
- [x] Persist `auto_switch.interval_seconds` and migrate registry schema `3 -> 4`.
- [x] Replace hard-coded poll intervals with config-driven scheduling on all platforms.
- [x] Clamp sub-minute Windows intervals to `1m` with an English warning.
- [x] Update docs to describe the new flag, schema version, and platform behavior.
- [x] Add or update tests for parsing, migration, rendering, and service interval handling.
- [x] Validate locally with the required Zig commands and record outcomes here.
- [ ] Commit the bootstrap plan changes, push the branch, and create a Draft PR.
- [ ] Drive the PR through CI, GitHub review comments, and `codex review` loops.
- [ ] Remove the temporary `AGENTS.md` execution lock in the final cleanup commit.

## Implementation log
- 2026-03-20: Created the execution plan and prepared to add the temporary `AGENTS.md` execution lock.
- 2026-03-20: Implemented `config auto --interval <integer><s|m|h>` parsing, help/status interval rendering, registry schema `4`, and config-driven interval handling in the auto-switch runtime.
- 2026-03-20: Updated Linux timer generation, macOS daemon sleep handling, and Windows scheduled-task creation/matching to use the configured interval. Windows sub-minute values now warn and clamp to `1m`.
- 2026-03-20: Updated README and implementation/schema/manual-test docs to describe interval support and schema `4`.

## CI / PR log
- Local validation:
  - `zig build run -- list` -> passed
  - `zig build test` -> passed
  - `zig test src/main.zig -lc` -> failed due existing Zig environment/cache issue: `failed to check cache: manifest_create Unexpected` while loading `std.zig`

## Review ledger
- Pending.

## Testing and validation
- Required after any `.zig` change: `zig build run -- list`
- Additional validation target: `zig test src/main.zig -lc`
- Add or update tests for:
  - valid `4s`, `4m`, `4h`
  - invalid interval inputs and mixed action/config rejection
  - schema `3 -> 4` default interval migration
  - help/status interval rendering
  - Linux/macOS/Windows interval handling

## Risks and edge cases
- Windows Task Scheduler does not support sub-minute repetition, so the CLI must normalize the saved/displayed value on Windows instead of silently drifting from the configured value.
- Adding a persisted field requires a schema bump because unknown fields are dropped on save by older binaries.
- The macOS daemon is long-running, so interval changes must be picked up by the loop itself rather than by plist changes alone.
- Service-definition matching must include interval-sensitive data so Linux/Windows installs refresh when the interval changes.

## Assumptions
- Canonical interval display stays lowercase and uses exactly one unit suffix.
- Composite durations such as `1h30m` remain unsupported.
- This plan file stays in the repository after completion; only the temporary `AGENTS.md` execution lock is removed.
