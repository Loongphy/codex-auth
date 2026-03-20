---
name: auto-switch-interval
description: Final implementation record for background auto-switching and configurable polling intervals
---

# Final Result

`codex-auth` now supports background auto-switching with configurable polling intervals.

## Delivered Behavior
- New command: `codex-auth config auto --interval` for auto-switch polling intervals.
- Background auto-switching is controlled through `codex-auth config auto enable`, `codex-auth config auto disable`, and `codex-auth config auto [--interval <duration>] [--5h <percent>] [--weekly <percent>]`.
- `status` reports whether auto-switching is enabled, the managed-service runtime state, the effective interval, and the configured thresholds.
- `help` and `README.md` document the auto-switch state and interval-aware configuration surface.
- The daemon switches silently when the active account drops below either threshold:
  - `5h` remaining `< 10%`
  - `weekly` remaining `< 5%`
- Accounts without stored usage are treated as fresh candidates.
- Candidate selection is reset-aware, treats free single-weekly-window snapshots as valid auto-switch candidates, and only switches when the best candidate is strictly better than the current account.

## Persistence And Compatibility
- `registry.json.schema_version` remains `3`.
- `auto_switch.interval_seconds` is persisted as part of the current schema-3 layout with default `60`.
- Current-layout registries that do not yet contain `auto_switch.interval_seconds` are loaded with the default interval and rewritten in normalized form when saved.
- Legacy `version = 2` registries still auto-migrate to the current layout.
- The registry also persists:
  - `auto_switch.enabled`
  - `auto_switch.threshold_5h_percent`
  - `auto_switch.threshold_weekly_percent`
  - `active_account_activated_at_ms`
  - per-account `last_local_rollout`

## Runtime And Platform Behavior
- Linux/WSL uses a managed `systemd --user` oneshot service plus timer at the configured interval.
- macOS uses a `LaunchAgent`; the long-running daemon re-reads the configured interval on subsequent cycles.
- Windows uses a user scheduled task registered from XML with a repeating time trigger at the configured interval.
- On Windows, intervals below `1m` are warned about in English and clamped to `1m`.
- Windows scheduled-task creation now safely escapes apostrophes in helper paths.

## Validation Outcome
- Local validation passed with:
  - `zig build run -- list`
  - `zig build test`
  - `zig test src/main.zig -lc --cache-dir /tmp/codex-auth-zig-cache --global-cache-dir /tmp/codex-auth-zig-global-cache`
- PR `#22` has no GitHub reviews or review comments; only the preview-package bot comment is present.
- `codex review --base main` did not yield a stable final summary because the Codex account hit usage limits during repeated review attempts.
