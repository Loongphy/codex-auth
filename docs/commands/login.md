# `codex-auth login`

## Usage

```shell
codex-auth login
codex-auth login --device-auth
```

## Behavior

- Runs `codex login`, or `codex login --device-auth` when requested.
- Reads the resulting `auth.json` from the active Codex home.
- Adds or updates the current account in `registry.json`.
- Stores a managed account snapshot under `accounts/<account file key>.auth.json`.
- Makes the logged-in account active when import succeeds.

## Notes

- `codex` must be available on `PATH`.
- Login-created accounts do not get an alias. Use `import <file> --alias <alias>` when an alias is needed.
- Invalid or incomplete auth files are rejected with the same auth validation rules used by `import`.
