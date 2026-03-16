# Codex Auth

> [!IMPORTANT]
> Usage refresh can now read from the ChatGPT usage API with `codex-auth config api enable`.
> This was added because local rollout/session files now often contain empty `rate_limits`, which makes local-only refresh unreliable.
> The API mode is still off by default in the current release for a safer rollout, but it is planned to become the default in `v0.3`.
>
> Current default: `codex-auth config api disable`
> Planned `v0.3` default: `codex-auth config api enable`

![command list](https://github.com/user-attachments/assets/7bbd463b-c5ed-4b90-b1f6-8dfbf21a8944)

`codex-auth` is a command-line tool for switching Codex accounts.

- It reads and updates local Codex files under `~/.codex` (including `sessions/` and auth files).
- `codex-auth list` and the background auto-switch worker refresh the active account's usage using one configured source: API-only when `config api enable` is on, or local rollout files only when `config api disable` is on.

> [!IMPORTANT]
> After switching accounts, you must fully exit `codex` and start it again for the new account to take effect.
> If you want seamless automatic account switching without restarting `codex`, use [codext](https://github.com/Loongphy/codext), but you need to build it yourself because there is no prebuilt install method yet.

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
codex-auth login # run `codex login`, then add the current account
codex-auth switch [<email>] # switch active account (interactive or partial/fragment match)
codex-auth import <path> [--alias <alias>] # smart import: file -> single import, folder -> batch import
codex-auth import --purge [<path>] # rebuild registry.json from auth files for the current version
codex-auth remove # remove accounts (interactive multi-select)
codex-auth status # show auto-switch/service/api usage status
codex-auth config auto enable|disable # manage background auto-switching
codex-auth config auto --5h <percent> [--weekly <percent>] # configure auto-switch thresholds
codex-auth config api enable|disable # choose API-only or local-sessions-only usage refresh
```

Compatibility note: `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`.

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

Rebuild `registry.json` from imported auth files:

```shell
codex-auth import --purge /path/to/auth-exports
codex-auth import --purge                  # rebuild from ~/.codex/accounts/*.auth.json
```

Switch accounts (interactive list shows email, 5h, weekly, last activity):

```shell
codex-auth switch               # arrow + number input
```

The switch picker uses the stored usage snapshot; it does not refresh usage before switching.

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

Show current status:

```shell
codex-auth status
```

Enable background auto-switching:

```shell
codex-auth config auto enable
```

Configure auto-switch thresholds:

```shell
codex-auth config auto --5h 12
codex-auth config auto --5h 12 --weekly 8
```

Use API-only usage refresh:

```shell
codex-auth config api enable
```

Use pure local rollout refresh without any API calls:

```shell
codex-auth config api disable
```

When auto-switching is enabled, a background worker refreshes the active account's usage from the configured source and silently switches accounts when:

- 5h remaining drops below the configured 5h threshold (default `10%`), or
- weekly remaining drops below the configured weekly threshold (default `5%`)

Accounts without any usage snapshot are treated as fresh accounts with full quota when ranking candidates.
On Linux/WSL, background checks run through `systemd --user` as a oneshot service triggered every minute by a timer. On Windows, a user scheduled task runs the same one-shot check every minute. On macOS, the background worker remains long-running.
Successful foreground `codex-auth` commands also reconcile the managed auto-switch service, so a disabled config removes stale background units while an enabled background worker is refreshed onto the current binary after upgrades or stale service drift.
Changing thresholds updates `registry.json`; Linux/WSL and Windows pick them up on the next scheduled run, while macOS picks them up on the next polling cycle, without a service restart.
Changing `config api` updates `registry.json` immediately; `api enable` means API-only and `api disable` means local-sessions-only.
`codex-auth help` also shows whether auto-switching and usage API calls are currently enabled.
