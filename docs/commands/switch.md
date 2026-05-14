# `codex-auth switch`

## Usage

```shell
codex-auth switch [--api|--skip-api]
codex-auth switch --live [--api|--skip-api]
codex-auth switch <query>
```

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

## Switch Effects

When switching succeeds:

1. `auth.json` is backed up when its contents would change.
2. The selected account snapshot is copied to `~/.codex/auth.json`.
3. `active_account_key` is updated in `registry.json`.
