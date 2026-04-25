# `codex-auth clean`

## Usage

```shell
codex-auth clean
```

## Behavior

- Cleans managed files under `~/.codex/accounts/`.
- Keeps live account snapshot files referenced by `registry.json`.
- Deletes stale managed snapshot files that are no longer referenced.
- Prunes managed backup files according to the backup retention rules.

If `accounts/registry.json` is missing, `clean` still prunes backup files but skips stale snapshot deletion so recovery snapshots remain available for `import --purge` or manual repair.

## Related Docs

- Backup behavior: [docs/implement.md](../implement.md)
- Registry repair: [docs/commands/import.md](./import.md)
