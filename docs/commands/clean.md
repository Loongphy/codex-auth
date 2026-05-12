# `codex-auth clean`

## Usage

```shell
codex-auth clean
codex-auth clean background
```

## Behavior

- Cleans managed files under `~/.codex/accounts/`.
- Keeps live account snapshot files referenced by `registry.json`.
- Deletes stale managed snapshot files that are no longer referenced.
- Prunes managed backup files according to the backup retention rules.

If `accounts/registry.json` is missing, `clean` still prunes backup files but skips stale snapshot deletion so recovery snapshots remain available for `import --purge` or manual repair.

`clean background` removes legacy background registrations created by older versions:

- Linux user units named `codex-auth-autoswitch.service` and `codex-auth-autoswitch.timer`.
- macOS LaunchAgent `com.loongphy.codex-auth.auto`.
- Windows scheduled task `CodexAuthAutoSwitch`.

This is a one-time migration cleanup command. It does not install, start, or run background refresh.

## Related Docs

- Backup behavior: [docs/implement.md](../implement.md)
- Registry repair: [docs/commands/import.md](./import.md)
