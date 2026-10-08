# `codex-auth switch`

## Usage

```shell
codex-auth switch -
codex-auth switch [--api|--skip-api]
codex-auth switch --live [--api|--skip-api]
codex-auth switch <query>
codex-auth switch <query> --json
codex-auth switch [<query>|-] --restart-daemon
```

## Previous Switch

`codex-auth switch -` switches to the previous active account.

- `codex-auth -` is a shortcut for the same behavior.
- The command fails when no previous account has been recorded.
- The command fails when the recorded previous account was removed.
- `switch -` does not accept `--live`, `--api`, or `--skip-api`.
- Previous-account switching is a human CLI convenience and cannot be combined with `--json`.

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

- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

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

Modern Codex clients can share a background app-server daemon that caches authentication. Updating `auth.json` alone may leave that daemon using the previous account, including when another terminal client connects.

One-shot switches detect a responsive daemon and print a restart hint on stderr. Restarting is opt-in:

```shell
codex-auth switch personal --restart-daemon
codex-auth switch - --restart-daemon
codex-auth switch personal --json --restart-daemon
```

`--restart-daemon` requests a restart after account activation and registry persistence succeed. It also restarts when the selected credentials are already on disk, so it can repair stale daemon authentication or retry a failed restart. It can interrupt all attached sessions. Reconnect, verify the account, and resume work as needed.

- The selected `CODEX_HOME` is passed to both lifecycle commands. The home’s managed executable is preferred, with supported legacy layouts and a PATH fallback.
- Responsiveness is checked with `codex app-server daemon version`. A missing control endpoint is treated as best-effort absence: no daemon is started. A stale endpoint or other probe error leaves the state unconfirmed; an explicit request then fails without invoking restart.
- The responsiveness check occurs immediately before restart. If the daemon disappears afterward, Codex’s supported restart command can start one; this race is accepted.
- The restart helper has a fixed 120-second timeout. Failure or timeout preserves the selected files, reports an unconfirmed daemon account state, and returns exit code 1. Only the helper process is terminated and reaped on timeout; daemon shutdown/startup may already have begun. No automatic retry or credential rollback occurs.
- Diagnostics and manual status/recovery commands are printed on stderr, with the selected home and executable. A successful version response proves responsiveness, not account identity.
- In JSON mode, stdout remains the existing switch-selection document. It can accompany exit code 1 when the subsequent requested restart fails.
- `--restart-daemon` is rejected with `--live`. Live switching, login, import, and remove retain their existing activation behavior and may also require manual daemon coordination.
- Older installations without a daemon endpoint remain a successful no-op. Platforms outside Linux, macOS, and Windows receive an honest unsupported-coordination hint for explicit requests.

No daemon-restart preference is persisted and the registry schema is unchanged.
