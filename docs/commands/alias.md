# `codex-auth alias`

## Usage

```shell
codex-auth alias set <query> <alias>
codex-auth alias clear <query>
```

## Selector Rules

`<query>` resolves from stored local data only. It does not trigger API refresh.

Selectors can match:

- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

If one account matches, the command updates that account immediately. If multiple accounts match, the command falls back to interactive selection in a TTY.

## Set Alias

`codex-auth alias set <query> <alias>` stores an alias in `registry.json` for the matched account.

- Empty aliases are rejected.
- All-digit aliases are rejected because numeric selectors already refer to displayed row numbers.
- Alias comparison is case-insensitive for duplicate detection.
- Changing an alias updates only stored registry metadata.

## Clear Alias

`codex-auth alias clear <query>` removes the stored alias for the matched account.

If the alias is already empty, the command reports that state and leaves the registry unchanged.
