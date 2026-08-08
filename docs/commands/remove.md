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

- The default picker stays local-only so deletion is not blocked by refresh work.
- `--api` attempts a best-effort foreground refresh for picker display.
- `--skip-api` explicitly forbids remote refresh.
- `q` quits without deleting accounts.

## Live Remove

`codex-auth remove --live` keeps the picker open after each deletion.

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
