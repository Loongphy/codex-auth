# `codex-auth remove`

## Usage

```shell
codex-auth remove [--api|--skip-api]
codex-auth remove --live [--api|--skip-api]
codex-auth remove <query> [<query>...]
codex-auth remove --all
codex-auth remove (<query> [<query>...]|--all) --json
```

## Interactive Remove

`codex-auth remove` opens the remove picker.

- The picker performs a strict foreground refresh over stored accounts by default (the same rules as interactive `switch`); an error from the refresh itself — for example, a missing `curl` — aborts `remove` with an error instead of showing a picker. Per-account request failures are not fatal and mark the affected rows instead.
- `--api` explicitly selects the API path (equivalent to the default when the usage API is enabled).
- `--skip-api` keeps the picker local-only: no foreground usage refresh.
- `q` quits without deleting accounts.

## Live Remove

`codex-auth remove --live` keeps the picker open after each deletion.

- It follows the same refresh policy as `switch --live`: an error from the initial refresh itself falls back to stored rows, `--api` makes the initial load strict, and `--skip-api` keeps it local-only.
- Removed rows disappear from the current display immediately.
- Existing row overlays stay in place until the next scheduled refresh.
- The active account shown after deletion comes from the persisted registry state.

## Query Remove

`codex-auth remove <query> [<query>...]` removes one or more accounts using stored local data.

Selectors first try an exact `account_key` match. Otherwise, they can match:

- displayed row number,
- alias fragment,
- email fragment,
- account name fragment, or
- `account_key` fragment.

Selector-based remove does not accept `--live`, `--api`, or `--skip-api`.

If a selector matches multiple accounts in a TTY, `remove` asks for confirmation. If stdin is not a TTY, ambiguous matches fail and the user must refine the selector.

With `--json`, selector-based remove never asks for confirmation. Every selector
is resolved before deletion. If any selector is ambiguous or missing, no
account is removed and one JSON error reports all selector resolutions.

## Remove All

`codex-auth remove --all` clears all accounts tracked in `registry.json`.

- It does not accept `--live`, `--api`, or `--skip-api`.
- `--json` emits one machine-readable JSON document.
- It deletes managed account snapshots and matching managed backups.
- It leaves malformed or unidentifiable backup files in place.

## Active Account Reconciliation

When the removed account was active:

- another remaining account is promoted when possible,
- `auth.json` is rewritten from the promoted account when safe,
- `auth.json` is deleted when no accounts remain and the current auth matches a tracked removed account,
- malformed or unsyncable `auth.json` is left untouched.

After a successful deletion, stdout prints `Removed N account(s): ...` in removal order.

Selector resolution is logically atomic for both human and JSON modes. A
filesystem failure after mutation starts may still leave state partially
changed; JSON reports this as `state_uncertain`, after which callers must list
state again before retrying.
