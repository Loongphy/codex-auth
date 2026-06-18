# `codex-auth reset`

## Usage

```shell
codex-auth reset <query> --yes
```

## Behavior

- Consumes one rate-limit reset credit for a stored ChatGPT account.
- Requires `--yes`; without it, the command refuses to consume a credit.
- Uses stored account auth from `CODEX_HOME/accounts`.
- Updates the stored reset-credit count when the account already has one.

## Selector Rules

`<query>` resolves from stored local data only. It does not trigger API refresh.

Selectors can match:

- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

If multiple accounts match, use a displayed row number from `codex-auth list`.

## Examples

```shell
codex-auth reset 02 --yes
codex-auth reset work --yes
```
