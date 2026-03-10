# Codex Auth

![command list](https://github.com/user-attachments/assets/7bbd463b-c5ed-4b90-b1f6-8dfbf21a8944)

`codex-auth` is a local-only command-line tool for switching Codex accounts.

- It never calls OpenAI APIs; all operations happen locally on your machine.
- It reads and updates local Codex files under `~/.codex` (including `sessions/` and auth files).

## Install

- npm:

```shell
npm install -g @loongphy/codex-auth
```

  You can also run it without a global install:

```shell
npx @loongphy/codex-auth list
```

  npm packages currently support Linux x64, macOS x64, macOS arm64, and Windows x64.

- Linux/macOS/WSL2:

```shell
curl -fsSL https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.sh | bash
```

  The installer writes the install dir to your shell profile by default.
  Supported profiles: `~/.bashrc`/`~/.bash_profile`/`~/.profile`, `~/.zshrc`/`~/.zprofile`, `~/.config/fish/config.fish`.
  Use `--no-add-to-path` to skip profile updates.

- Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.ps1 | iex
```

  The installer adds the install dir to current/user `PATH` by default.
  Use `-NoAddToPath` to skip user `PATH` persistence.

## Full Commands

```shell
codex-auth list # list all accounts
codex-auth login [--skip] # login and add current account (runs `codex login` by default)
codex-auth switch [<email>] # switch active account (interactive or partial/fragment match)
codex-auth import <path> [--alias <alias>] # smart import: file -> single import, folder -> batch import
codex-auth remove # remove accounts (interactive multi-select)
codex-auth auto enable|disable|status # manage background auto-switching
```

Compatibility note: `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`. The old `--no-login` flag has been replaced by `--skip`.

### Examples

List accounts (default table with borders):

```shell
codex-auth list
```

Add the currently logged-in Codex account:

```shell
codex-auth login
```

Import an auth.json backup:

```shell
codex-auth import /path/to/auth.json --alias personal
```

Batch import from a folder:

```shell
codex-auth import /path/to/auth-exports
```

Switch accounts (interactive list shows email, 5h, weekly, last activity):

```shell
codex-auth switch               # arrow + number input
```

![command switch](https://github.com/user-attachments/assets/48a86acf-2a6e-4206-a8c4-591989fdc0df)

Switch account non-interactively (for scripts/other CLIs):

```shell
codex-auth switch user
```

If multiple accounts match, interactive selection is shown.

Remove accounts (interactive multi-select):

```shell
codex-auth remove
```

Enable background auto-switching:

```shell
codex-auth auto enable
```

Show background auto-switch status:

```shell
codex-auth auto status
```

When auto-switching is enabled, a background daemon watches the active account's latest rollout usage and silently switches accounts when:

- 5h remaining drops below `10%`, or
- weekly remaining drops below `5%`

Accounts without any usage snapshot are treated as fresh accounts with full quota when ranking candidates.
`codex-auth help` also shows whether auto-switching is currently `ON` or `OFF`.
