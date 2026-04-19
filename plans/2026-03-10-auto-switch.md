---
name: auto-switch
description: Add background account auto-switching with manual enable/disable/status control
---

# Plan

Add a background auto-switch daemon to `codex-auth`. The feature must be off by default, manually controlled via `codex-auth auto enable|disable|status`, and shown in `help`. When enabled, the daemon silently switches away from the active account if its remaining quota falls below the configured thresholds.

## Requirements
- Add `codex-auth auto enable`, `codex-auth auto disable`, and `codex-auth auto status`.
- Show the current auto-switch state in `codex-auth help`.
- Keep auto-switch disabled by default for existing and new users.
- Run a real background daemon instead of checking only during foreground commands.
- Trigger a switch when the active account has:
  - `5h` remaining `< 10%`, or
  - `weekly` remaining `< 5%`
- Consider all non-active accounts as switch candidates.
- Treat accounts without any usage snapshot as fresh accounts with `5h=100%` and `weekly=100%`.
- Use reset-aware usage logic: if a stored window has already passed `resets_at`, treat that window as fully reset (`100%` remaining).
- Switch silently with no extra stdout/stderr user notification.
- Support cross-restart auto-start on all supported platforms:
  - Linux/WSL via `systemd --user`
  - macOS via `LaunchAgent`
  - Windows via a user scheduled task

## Scope
- In: CLI command changes, registry persistence, background daemon, service registration, usage selection logic, docs/help/readme updates, and automated tests.
- Out: configurable thresholds, GUI/system tray controls, and Windows-assisted WSL startup.

## Files and entry points
- `src/cli.zig` for `auto` command parsing and help output
- `src/main.zig` for foreground command handling plus daemon entrypoint wiring
- `src/registry.zig` for persisted auto-switch config and candidate scoring
- `src/sessions.zig` for rollout-source-aware usage scanning
- New daemon/service helper module under `src/` for background loop and OS service integration
- `src/tests/*.zig` for CLI, registry, daemon, and rollout-attribution coverage
- `docs/implement.md` and `README.md` for user-facing and implementation docs

## Data model / API changes
- Bump `registry.json` to `version: 3`.
- Add top-level `auto_switch` state:
  - `enabled: bool`
  - `session_tracker` metadata that records the last rollout file path/mtime and which account currently owns that rollout source
- Keep registry v2 backward compatible by defaulting `auto_switch.enabled` to `false` and an empty tracker.
- Add internal daemon-only command surface `codex-auth daemon --watch` for service managers.

## Action items
[ ] Add the plan file and keep implementation aligned with it.
[ ] Extend CLI parsing/help with `auto enable|disable|status`, and print current ON/OFF state in help.
[ ] Persist `auto_switch` state in the registry with backward-compatible load/save behavior.
[ ] Add rollout source tracking so the same latest rollout file is not reassigned to a different account immediately after a switch.
[ ] Implement reset-aware remaining-percentage helpers and candidate scoring:
  - current-account trigger: `5h < 10` or `weekly < 5`
  - candidate scoring: min(`5h`, `weekly`) when both are known, otherwise the known window
  - no-snapshot accounts score as `100`
  - ties break by newer `last_usage_at`, then newer `created_at`, then stable registry order
  - switch only when the best candidate score is strictly better than the current score
[ ] Add a single-instance daemon loop that periodically refreshes usage, evaluates thresholds, and performs silent account switching by rewriting `auth.json` and `active_email`.
[ ] Implement platform service registration helpers:
  - Linux/WSL: install/remove `systemd --user` service and run `daemon-reload` + `enable --now` / `disable --now`
  - macOS: install/remove `LaunchAgent`
  - Windows: install/remove user scheduled task
[ ] Make `auto status` report config state and service runtime state.
[ ] Update `README.md` and reconcile `docs/implement.md` with the new background behavior.
[ ] Add tests for CLI parsing, registry migration, candidate selection, no-snapshot scoring, rollout attribution, and service-definition generation.

## Testing and validation
- `zig build test`
- `zig build run -- list`
- Add unit/BDD tests for:
  - `auto enable|disable|status`
  - help showing ON/OFF
  - registry v2 -> v3 compatibility
  - switch trigger on `5h < 10`
  - switch trigger on `weekly < 5`
  - reset-aware candidate evaluation
  - no-snapshot candidate treated as `100%`
  - no switch when no better candidate exists
  - rollout source is not misattributed after an automatic switch
  - generated Linux/macOS/Windows service payloads or command arguments

## Risks and edge cases
- The latest rollout file is not account-tagged, so rollout-source ownership tracking is required to avoid copying old-account usage onto the newly active account after a switch.
- Newly added accounts without usage snapshots will outrank partially depleted accounts by design; tie-breaking must stay deterministic.
- WSL is treated as Linux and depends on `systemd --user`; environments without it are out of scope for this feature.
- Service-install commands must be idempotent so repeated `auto enable` / `auto disable` calls do not fail unnecessarily.

## Assumptions
- Thresholds are fixed in code at `5h < 10%` and `weekly < 5%`.
- Silent switching means no user-facing switch notice beyond state changes visible in `list`, `help`, or `auto status`.
- For WSL, no Windows-side bootstrap is required; Linux-side `systemd --user` is the only supported startup path.
