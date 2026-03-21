# Auto-Switch Implementation

This document is the single source of truth for `codex-auth` background auto-switch behavior.

## Commands and Stored Config

User-facing commands:

- `codex-auth config auto enable`
- `codex-auth config auto disable`
- `codex-auth config auto [--5h <percent>] [--weekly <percent>]`
- `codex-auth config api enable`
- `codex-auth config api disable`

Stored registry fields:

- `auto_switch.enabled`
- `auto_switch.threshold_5h_percent`
- `auto_switch.threshold_weekly_percent`
- `api.usage`

The feature is off by default.

## Runtime Model

When enabled, managed services run the long-lived watcher mode:

- `codex-auth daemon --watch`

The watcher keeps a single process alive and runs roughly once per second.
Each cycle:

1. loads `registry.json`
2. syncs the currently active `auth.json` into the registry
3. refreshes missing account metadata from stored auth snapshots when needed
4. tries to refresh usage from the newest local rollout event first
5. if no new local rollout event is available, or the newest event has no usable rate-limit windows, and `api.usage = true`, falls back to the ChatGPT usage API at most once per minute for the current active account
6. evaluates whether the active account should be switched
7. writes `registry.json` only when state changed

`daemon --once` still exists for tests and one-shot validation, but the managed service path uses `daemon --watch`.

## Data Source Priority

The background watcher is intentionally not API-only, even when `api.usage = true`.

- Local rollout events are preferred because they arrive much faster than periodic usage API polling.
- API refresh remains useful as a slower fallback and calibration path when rollout data is missing or stale.
- When `api.usage = false`, the watcher uses local rollout data only and makes no usage API requests.
- When a new rollout event arrives but its `rate_limits` payload is `null`, `{}`, or otherwise lacks usable 5h/weekly windows, the watcher keeps the previous `last_usage` snapshot and relies on the API fallback path instead of overwriting usage with empty data.
- The watcher resets the active-account API fallback cooldown when `active_account_key` changes, so a newly active account is not forced to wait behind the previous account's cooldown window.

Local rollout attribution rules are unchanged:

- only the newest `~/.codex/sessions/**/rollout-*.jsonl` file is considered
- in watcher mode, the newest rollout file is cached in memory and rechecked cheaply between bounded full rescans, so large session trees are not fully walked every second
- the last usable `token_count` event in that file is used
- a newer `token_count` event with unusable `rate_limits` is still treated as a fresh signal for API fallback, but it does not overwrite the stored usage snapshot
- the event is applied only when `event_timestamp_ms >= active_account_activated_at_ms`
- each account remembers its own last consumed local rollout signature `(path, event_timestamp_ms)` so the same local event is not reapplied

## Switching Rules

The watcher switches without foreground CLI output when the active account drops below either threshold:

- `5h remaining < auto_switch.threshold_5h_percent`
- `weekly remaining < auto_switch.threshold_weekly_percent`

There is one extra near-real-time safety rule for free plans:

- when the 5h trigger comes from an actual 300-minute window or an unlabeled primary window, the effective 5h threshold for `free` accounts is `max(configured_5h_threshold, 35%)`

This higher floor exists because free accounts can burn through the last visible quota much faster than once-per-minute checks can react.

Candidate scoring is reset-aware:

- if `resets_at <= now`, that window is treated as `100%`
- if both 5h and weekly are known, the candidate score is the lower remaining percentage
- if only one window is known, that window becomes the score
- free accounts that expose only a single `10080`-minute weekly window remain eligible auto-switch candidates and use that weekly remaining percentage as their score
- when `api.usage = true` and auto-switch is about to leave the current account, candidate ChatGPT accounts are refreshed from their stored auth snapshots before the final switch decision
- in watcher mode, repeated candidate revalidation for the same active account is throttled instead of running on every 1-second loop
- if no usage snapshot exists after that refresh step, the account is treated as fresh with score `100`
- switching happens only when the best candidate scores strictly better than the current account

## Service Model

Platform bootstrap:

- Linux/WSL: `systemd --user` persistent service
- macOS: `LaunchAgent` with `KeepAlive`
- Windows: user scheduled task with an `ONLOGON` trigger, restart-on-failure settings, and an unlimited execution time for `codex-auth-auto.exe`, plus an immediate `schtasks /Run` during enablement

Service install paths still resolve from the real user home directory.
Foreground commands other than `help`, `version`, `status`, and `daemon` still reconcile the managed service definition after they complete.

## Limits

The watcher can react within about one polling interval after a new rollout event lands, but it still cannot rescue a request that has already failed because the quota was exhausted inside that same request.

In other words:

- this design materially reduces the gap between usage changes and switching
- it does not provide request-level retry/failover by itself
