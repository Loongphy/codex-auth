# `codex-auth auto`

Monitor account usage in the foreground and switch stored credentials when the
active account nears a rate limit. Stop with Ctrl-C. This command does not install
background services or restart clients. Standard Codex CLI and App clients may
need restarting before they use the selected account.

## Usage

```shell
codex-auth auto
codex-auth auto --threshold 85 --interval 60 --cooldown 300
codex-auth auto --once --dry-run --json
```

| Option | Default | Accepted values |
|--------|---------|-----------------|
| `--threshold` | `90` | Used quota percentage, `50` through `99.9` |
| `--interval` | `60` | Seconds between completed polls, `15` through `3600` |
| `--cooldown` | `300` | Seconds since account activation, `0` through `86400` |
| `--once` | off | Evaluate once and exit |
| `--dry-run` | off | Report decisions without changing registry or credential files |
| `--json` | off | Emit one JSON event per poll |

## Selection

Auto requires a current registry layout. If it reports `RegistryMigrationRequired`,
run an explicit account-management command such as `list` to complete the existing
registry migration first. Auto itself never migrates registry files.

Each poll requests fresh API usage for stored ChatGPT accounts. The command
requires a successful response for the active account. Cached data, missing
usage, expired response windows, invalid percentages and failed requests cannot
justify a switch. API-key accounts are excluded, avoiding a switch into paid API
usage. There is no `--skip-api` mode.

Switching triggers when any reported quota window reaches the threshold and the
activation cooldown has elapsed. A target must have every reported window below
the threshold. The account with the most remaining quota in its most-used window
wins; ties retain registry order. An account reporting only one window is ranked
by that window. Missing windows are not assumed to have unlimited capacity.

The command checks that `auth.json` matches the registry before polling and again
before switching, and reloads the registry after network requests to preserve
unrelated edits. It uses the existing activation path, including credential
backup and previous-account tracking. Usage fetched by this command is used for
the decision without updating the stored usage cache.

An exclusive `CODEX_HOME/auto.lock` prevents multiple mutating auto monitors from
running together. The lock file remains after exit; the operating system releases
the lock when the process exits. Dry-run does not create or acquire this lock.
Other commands do not participate in this lock; avoid concurrent manual account
mutations while auto monitoring runs.

## Results

Normal evaluations exit `0` in one-shot mode, including decisions that do not
switch. Operational failures exit `1`; invalid arguments exit `2`. Loop mode
reports operational failures and retries after the polling interval.

JSON decisions contain `schema_version: 1`, `command: "auto"`, `status`,
`dry_run`, `from` and `to` account keys. Status values:

- `held`: active usage is below the threshold.
- `cooldown`: the activation cooldown has not elapsed.
- `blocked`: fresh usage, matching active credentials, or an eligible target is unavailable; or the active account changed during refresh.
- `would_switch`: dry-run selected a target.
- `switched`: credentials and registry were saved successfully.

Operational errors use the existing JSON error format with `auto_error` or
`auto_running`. No tokens or credential contents are printed.
