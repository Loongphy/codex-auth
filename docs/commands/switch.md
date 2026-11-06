# `codex-auth switch`

## Usage

```shell
codex-auth - [--json] [--no-restart-daemon]
codex-auth switch [--api|--skip-api] [--no-restart-daemon]
codex-auth switch --live [--api|--skip-api] [--no-restart-daemon]
codex-auth switch <query> [--no-restart-daemon]
codex-auth switch <query> --json [--no-restart-daemon]
```

## Previous Switch

`codex-auth -` switches to the previous active account. It is a shortcut form of `codex-auth switch`: it takes no positional argument and supports the same one-shot flags as query switching (`--json`, `--no-restart-daemon`), but not the picker-mode flags (`--live`, `--api`, `--skip-api`).

- The command fails when no previous account has been recorded.
- The command fails when the recorded previous account was removed.
- Only the top-level `-` form is the shortcut: `codex-auth switch -` treats `-` as an ordinary account query.

## Interactive Switch

`codex-auth switch` opens the account picker and exits after one successful switch.

- The picker uses the same account ordering as `list`.
- `q` quits without switching.
- `--api` forces foreground remote refresh before rendering.
- `--skip-api` renders from stored data and local-only active-account refresh where available.

## Live Switch

`codex-auth switch --live` keeps the picker open after each successful switch.

- The display refreshes on a timer.
- A successful switch patches the current display immediately.
- In-flight refresh results are discarded after a manual switch.
- Existing usage overlays stay visible until the next scheduled refresh.

## Query Switch

`codex-auth switch <query>` resolves the target from stored local data and does not run remote refresh.

Selectors can match:

- account key,
- exact alias or email,
- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

Shell completion offers one stable selector per account (a unique alias or email, or the account key).

If one account matches, it switches immediately. If multiple accounts match, the command falls back to interactive selection. Query mode does not accept `--live`, `--api`, or `--skip-api`.

With `--json`, query mode never opens the interactive picker. Ambiguous queries fail with a JSON error document that includes candidate accounts.
The returned `switched_to.plan` is already normalized to the final product plan.

## Switch Effects

When switching succeeds:

1. `auth.json` is backed up when its contents would change.
2. The selected account snapshot is copied to `~/.codex/auth.json`.
3. `active_account_key` is updated in `registry.json`.
4. `previous_active_account_key` records the account that was active before the switch, when one exists.
5. The success message uses the same identity label as singleton rows, for example `Switched to me(test@example.com)`.

The previous-account pointer is internal CLI state and is not included in JSON responses.

## Applying a Switch to a Running Daemon

Modern Codex clients can share a background app-server daemon that caches authentication. Updating `auth.json` alone may leave that daemon using the previous account, including when another terminal client connects, so every one-shot switch also coordinates the daemon automatically — no flag is needed.

Daemons that support an in-place auth reload apply the credentials without interrupting attached sessions; a busy daemon skips the reload while a turn runs, so the switch should be rerun after the turn finishes. Daemons that do not support reload are restarted instead, which can interrupt all attached sessions. A daemon that accepts the reload command but reports a failure or does not answer within the reload deadline is left running, because a timeout is not evidence of a missing command and a restart would interrupt sessions for nothing. This covers stale daemon authentication, unchanged-file recovery, and retries after a failed attempt. Reconnect, verify the account, and resume work as needed.

`--no-restart-daemon` caps coordination at the non-disruptive reload: the daemon is never restarted even when it cannot reload, and daemon issues never change the exit code. Use it when a running daemon's work must not be interrupted and you would rather coordinate it manually later. It also works with `--live`, where it keeps each apply non-blocking even against daemons that cannot reload.

- The selected `CODEX_HOME` is passed to both lifecycle commands. The home’s managed executable is preferred, with supported legacy layouts and a PATH fallback.
- Responsiveness is checked with `codex app-server daemon version` before any reload or restart. A missing control endpoint is treated as best-effort absence: no daemon is started. A stale endpoint or other probe error leaves the state unconfirmed; nothing is invoked and the switch still succeeds.
- The responsiveness check occurs immediately before restart. If the daemon disappears afterward, Codex’s supported restart command can start one; this race is accepted.
- The restart helper has a fixed 120-second timeout. Failure or timeout preserves the selected files, reports an unconfirmed daemon account state, and returns exit code 1. Only the helper process is terminated and reaped on timeout; daemon shutdown/startup may already have begun. No automatic retry or credential rollback occurs.
- Diagnostics and manual status/recovery commands are printed on stderr, with the selected home and executable. A successful version response proves responsiveness, not account identity.
- In JSON mode, the switch-selection document carries a `daemon` field with the coordination outcome (for example `reloaded`, `deferred`, `restarted`, or `restart_failed`). The document can still accompany exit code 1 when the daemon restart fails.
- `--live` runs the same coordination on a background thread after each accepted selection, reporting progress and the outcome on the status line without blocking input. Login, import, and remove retain their existing activation behavior and may also require manual daemon coordination.
- Older installations without a daemon endpoint remain a successful no-op. Platforms outside Linux, macOS, and Windows receive an honest unsupported-coordination hint.

No daemon-restart preference is persisted and the registry schema is unchanged.
