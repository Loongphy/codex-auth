# Command Reference

This directory documents command behavior by command. Use `codex-auth <command> --help` for the shortest in-terminal usage form.

## Commands

| Command | Details |
|---------|---------|
| `list` | [docs/commands/list.md](./list.md) |
| `login` | [docs/commands/login.md](./login.md) |
| `import` | [docs/commands/import.md](./import.md) |
| `export` | [docs/commands/export.md](./export.md) |
| `switch` | [docs/commands/switch.md](./switch.md) |
| `remove` | [docs/commands/remove.md](./remove.md) |
| `alias` | [docs/commands/alias.md](./alias.md) |
| `clean` | [docs/commands/clean.md](./clean.md) |
| `config` | [docs/commands/config.md](./config.md) |
| `app` | [docs/commands/app.md](./app.md) |

## Shared Behavior

- Commands resolve `codex_home` from `CODEX_HOME`, then `HOME/.codex`, then `USERPROFILE/.codex` on Windows.
- Account selection commands use the same row ordering and display grouping.
- `--api` explicitly selects the default remote usage and account-name refresh path for the current command.
- `--skip-api` forbids remote refresh for the current command.
- Local-only usage refresh can update the active account from local Codex rollout files when usable local data exists.
