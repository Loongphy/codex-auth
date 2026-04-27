# Auto-Switch Implementation

This document is the single source of truth for `codex-auth` background auto-switch behavior.

It does not describe the foreground `codex-auth switch --live --auto` picker mode. That live picker mode uses its own immediate display-driven trigger rules and does not read `auto_switch.threshold_5h_percent` or `auto_switch.threshold_weekly_percent`.

## Commands and Stored Config

User-facing commands:

- `codex-auth config auto enable`
- `codex-auth config auto disable`
- `codex-auth config auto [--5h <percent>] [--weekly <percent>]`
- `codex-auth config api enable`
- `codex-auth config api disable`
- `codex-auth group <name> auto enable`
- `codex-auth group <name> auto disable`
- `codex-auth group <name> auto [--5h <percent>] [--weekly <percent>]`
- `codex-auth group <name> config api enable`
- `codex-auth group <name> config api disable`

Stored registry fields:

- `auto_switch.enabled`
- `auto_switch.threshold_5h_percent`
- `auto_switch.threshold_weekly_percent`
- `api.usage`

The feature is off by default.

## Runtime Model

When enabled, the managed service runs the long-lived manager mode:

- `codex-auth daemon --manager`

The manager keeps a single process alive, loads all managed groups, and runs roughly once per second.
For every group whose own registry has `auto_switch.enabled = true`, each cycle:

1. keeps an in-memory candidate index for all non-active accounts, keyed by the same candidate score used for switching
2. reloads `registry.json` only when the on-disk file changed, then rebuilds that in-memory index
3. syncs the currently active `auth.json` into the in-memory registry when the active auth snapshot changed
4. tries to refresh usage from the newest local rollout event first
5. scans that group's rollout files for a fresh "hit your usage limit" message and marks the currently active account exhausted immediately when the message is newer than that account's activation time
6. if no new local rollout event is available, or the newest event has no usable rate-limit windows, and `api.usage = true`, falls back to the ChatGPT usage API at most once per minute for the current active account
7. keeps the candidate index warm with a bounded candidate upkeep pass instead of batch-refreshing every candidate
8. if the active account should switch, revalidates only the top few stale candidates before making the final switch decision
9. writes `registry.json` only when state changed

The watcher also emits English-only service logs for debugging:

- logs use compact `[local]`, `[api]`, and `[switch]` tags
- local rollout captures show the parsed window labels first, then the local-time event timestamp, then the real rollout basename; when the newest local event has no usable usage windows the same `[local]` line also marks `fallback-to-api`
- API refresh logs are reduced to `refresh usage | status=...`, where `status` is the HTTP status when available, `MissingAuth` when the active auth cannot call the ChatGPT usage API, or the direct transport error name such as `TimedOut` / `RequestFailed`

`daemon --watch` and `daemon --once` still exist for tests, legacy service cleanup, and one-CODEX_HOME validation. The managed service path uses `daemon --manager`; `daemon --manager-once` runs one manager pass.

## Data Source Priority

The background watcher is intentionally not API-only, even when `api.usage = true`.

- Local rollout events are preferred because they arrive much faster than periodic usage API polling.
- Local limit-message detection is even more direct: it watches each enabled group's own `<CODEX_HOME>/sessions/**/rollout-*.jsonl` tree, so project directories and terminal tabs do not matter as long as the session uses that group `CODEX_HOME`.
- API refresh remains useful as a slower fallback and calibration path when rollout data is missing or stale.
- When `api.usage = false`, the watcher uses local rollout data only and makes no usage API requests.
- When a new rollout event arrives but its `rate_limits` payload is `null`, `{}`, or otherwise lacks usable 5h/weekly windows, the watcher keeps the previous `last_usage` snapshot and relies on the API fallback path instead of overwriting usage with empty data.
- The watcher resets the active-account API fallback cooldown when `active_account_key` changes, so a newly active account is not forced to wait behind the previous account's cooldown window.
- API timeout and request-failure logs come from the same 5-second limit used by the underlying request path.

Local rollout attribution rules are unchanged:

- only the newest `~/.codex/sessions/**/rollout-*.jsonl` file is considered
- in watcher mode, the newest rollout file is cached in memory and rechecked cheaply between bounded full rescans, so large session trees are not fully walked every second
- the last usable `token_count` event in that file is used
- a newer `token_count` event with unusable `rate_limits` is still treated as a fresh signal for API fallback, but it does not overwrite the stored usage snapshot
- the event is applied only when `event_timestamp_ms >= active_account_activated_at_ms`
- each account remembers its own last consumed local rollout signature `(path, event_timestamp_ms)` so the same local event is not reapplied
- limit-message events also use the same activation-time guard; after a switch, the old limit message is older than the newly active account activation and will not immediately exhaust the replacement account

## Switching Rules

The watcher switches without foreground CLI output when the active account reaches or drops below either threshold:

- `5h remaining <= auto_switch.threshold_5h_percent`
- `weekly remaining <= auto_switch.threshold_weekly_percent`

There is one extra near-real-time safety rule for free plans:

- when the 5h trigger comes from an actual 300-minute window or an unlabeled primary window, the effective 5h threshold for `free` accounts is `max(configured_5h_threshold, 35%)`

This higher floor exists because free accounts can burn through the last visible quota much faster than once-per-minute checks can react.

Candidate scoring is reset-aware:

- if `resets_at <= now`, that window is treated as `100%`
- if both 5h and weekly are known, the candidate score is the lower remaining percentage
- if only one window is known, that window becomes the score
- free accounts that expose only a single `10080`-minute weekly window remain eligible auto-switch candidates and use that weekly remaining percentage as their score
- the watcher keeps that candidate score ordering in a daemon-local in-memory index; it is rebuilt on daemon start or whenever `registry.json` changes externally
- when `api.usage = true`, watcher upkeep refreshes at most one stale top candidate per cycle while the current account is still healthy
- when auto-switch is about to leave the current account, the watcher revalidates only the current heap top and then the next top candidates as needed, up to a small bounded budget, instead of refreshing every candidate
- candidate freshness bookkeeping is daemon-local runtime state and is not persisted to `registry.json`
- if no usage snapshot exists after that refresh step, the account is treated as fresh with score `100`
- switching happens only when the best candidate scores strictly better than the current account

## Service Model

Platform bootstrap:

- Linux/WSL: `systemd --user` persistent service
- macOS: `LaunchAgent` with `KeepAlive`
- Windows: user scheduled task with an `ONLOGON` trigger, restart-on-failure settings, and an unlimited execution time for `codex-auth-auto.exe`, plus an immediate task run during enablement

Service definition files stay in the platform-standard per-user locations. The managed manager process does not use one fixed `CODEX_HOME`; it reads `~/codex-auth/groups.json`, then runs each enabled group against that group's configured `CODEX_HOME`. The `default` group still maps to the normal `~/.codex`.
Foreground commands other than `help`, `version`, `status`, and `daemon` still reconcile the managed service definition after they complete.
`config auto enable` also prints a short usage-mode note so the user can see whether switching is currently running with default API-backed usage data or local-only fallback semantics.
The manager uses one service identity for all enabled groups: `codex-auth-manager.service` on Linux, `com.loongphy.codex-auth.manager` on macOS, and `CodexAuthManager` on Windows.
When the manager service is installed or reconciled, the CLI resolves the current usable Node executable from `CODEX_AUTH_NODE_EXECUTABLE` or `PATH` and writes it into the service environment as `CODEX_AUTH_NODE_EXECUTABLE`. This avoids hard-coding a user-specific path while still letting macOS LaunchAgent/systemd run API refreshes under their limited default `PATH`.
When migrating from older service layouts, enable/reconcile also removes legacy one-CODEX_HOME and per-group service identities such as `codex-auth-autoswitch.service`, `com.loongphy.codex-auth.auto`, `codex-auth-autoswitch-work.service`, and `com.loongphy.codex-auth.auto.work`.

## Limits

The watcher can react within about one polling interval after a new rollout event lands, but it still cannot rescue a request that has already failed because the quota was exhausted inside that same request.

In other words:

- this design materially reduces the gap between usage changes and switching
- it does not provide request-level retry/failover by itself
