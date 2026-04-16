# Codex Auth

![command list](https://github.com/user-attachments/assets/6c13a2d6-f9da-47ea-8ec8-0394fc072d40)

`codex-auth` is a command-line tool for switching Codex accounts.

> [!IMPORTANT]
> For **Codex CLI** and **Codex App** users, switch accounts, then restart the client for the new account to take effect.
>
> If you use the CLI and want seamless automatic account switching without restarting, use the forked [`codext`](https://github.com/Loongphy/codext), an enhanced Codex CLI. Install it with `npm i -g @loongphy/codext` and run `codext`.

## Supported Platforms

`codex-auth` works with these Codex clients:

- Codex CLI
- VS Code extension
- Codex App

For the best experience, install the Codex CLI even if you mainly use the VS Code extension or the App, because it makes adding accounts easier:

```shell
npm install -g @openai/codex
```

After that, you can use `codex login`, `codex login --device-auth`, `codex-auth login`, or `codex-auth login --device-auth` to sign in and add accounts more easily.

## Install

Install with npm:

```shell
npm install -g @loongphy/codex-auth
```

  You can also run it without a global install:

```shell
npx @loongphy/codex-auth list
```

  npm packages currently support Linux x64, Linux arm64, macOS x64, macOS arm64, Windows x64, and Windows arm64.

> [!NOTE]
> If you only installed `@loongphy/codex-auth` with npm, you do not need any legacy cleanup steps.
> Older Bash/PowerShell GitHub-release installs could leave a standalone `codex-auth` binary outside npm's install path.
> If you previously used those legacy installers, remove the leftover binaries and profile changes during migration.
> API-backed usage refresh and team-name refresh use Node.js `fetch`.
> npm installs already satisfy that requirement.
> Legacy standalone binary installs need Node.js 22+ on `PATH` when `codex-auth config api enable` is used.

## Storage Root

`codex-auth` uses the same Codex state root as the current process. Resolution order:

1. `CODEX_HOME` when set to a non-empty existing directory
2. `HOME/.codex`
3. `USERPROFILE/.codex` on Windows

When `CODEX_HOME` is set, `codex-auth` follows Codex and requires that directory to already exist.
That means you can isolate auth, registry, config, and session files by running:

```shell
CODEX_HOME=/path/to/custom-codex codex-auth list
```

### Uninstall

#### npm

Remove the npm package:

```shell
npm uninstall -g @loongphy/codex-auth
```

#### Legacy Bash Installer

For non-npm installs on Linux/macOS/WSL2 only:

```shell
rm -f ~/.local/bin/codex-auth
rm -f ~/.local/bin/codex-auth-auto
sed -i '/# Added by codex-auth installer/,+1d' ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc ~/.zprofile 2>/dev/null || true
```

If you used fish, also remove the old profile entry:

```shell
sed -i '/# Added by codex-auth installer/,+3d' ~/.config/fish/config.fish 2>/dev/null || true
```

#### Legacy PowerShell Installer

For non-npm installs on Windows only:

```powershell
Remove-Item "$env:LOCALAPPDATA\codex-auth\bin\codex-auth.exe" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\codex-auth\bin\codex-auth-auto.exe" -Force -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable(
  "Path",
  (($env:Path -split ';' | Where-Object { $_ -and $_ -ne "$env:LOCALAPPDATA\codex-auth\bin" }) -join ';'),
  "User"
)
```

## Commands

### Account Management

| Command | Description |
|---------|-------------|
| `codex-auth list [--debug]` | List all accounts |
| `codex-auth login [--device-auth]` | Run `codex login` (optionally with `--device-auth`), then add the current account |
| `codex-auth switch [<email>]` | Switch active account interactively or by partial match |
| `codex-auth remove` | Remove accounts with interactive multi-select |
| `codex-auth status` | Show auto-switch, service, and usage status |

### Import

| Command | Description |
|---------|-------------|
| `codex-auth import <path> [--alias <alias>]` | Import a single file or batch import from a folder |
| `codex-auth import --cpa [<path>]` | Import [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) token JSON |
| `codex-auth import --purge [<path>]` | Rebuild `registry.json` from existing auth files |

### Configuration

| Command | Description |
|---------|-------------|
| `codex-auth config auto enable\|disable` | Enable or disable experimental background auto-switching |
| `codex-auth config auto [--5h <%>] [--weekly <%>]` | Set experimental auto-switch thresholds |
| `codex-auth config api enable\|disable` | Enable or disable both usage refresh and team name refresh API calls |

---

## Examples

### List Accounts

```shell
codex-auth list
codex-auth list --debug
```

### Switch Account

Interactive: shows email, 5h, weekly, and last activity.

```shell
codex-auth switch
```

Before the picker opens, `switch` refreshes usage for all stored accounts with a maximum concurrency of `3`, so the picker is based on a fresh cross-account snapshot. If a refresh returns a non-`200` HTTP status such as `401` or `403`, that row shows the status in both usage columns. If a stored account snapshot cannot make a ChatGPT usage request at all because the required auth fields are missing, that row shows `MissingAuth` instead of the previous usage values. No extra usage refresh is attempted after the switch completes.

![command switch](https://github.com/user-attachments/assets/48a86acf-2a6e-4206-a8c4-591989fdc0df)

Non-interactive: fuzzy match by email or alias.

```shell
codex-auth switch john             # match any account containing "john"
codex-auth switch john@gmail.com   # match by full or partial email
codex-auth switch work             # match by alias set during import
```

If the keyword matches multiple accounts, the command falls back to interactive selection. Press `q` to quit without switching.

### Remove Accounts

```shell
codex-auth remove
```

### Login (Add Account)

Add the currently logged-in Codex account:

```shell
codex-auth login
codex-auth login --device-auth
```

### Import

#### Single File

```shell
codex-auth import /path/to/auth.json --alias personal
```

#### Batch Import from a Folder

Scans all `.json` files in the directory:

```shell
codex-auth import /path/to/auth-exports
```

Typical output:

```text
Scanning /path/to/auth-exports...
  ✓ imported  token_ryan.taylor.alpha@email.com
  ✓ updated   token_jane.smith.alpha@email.com
  ✗ skipped   token_invalid: MalformedJson
Import Summary: 1 imported, 1 updated, 1 skipped (total 3 files)
```

`stdout` carries scanning, success, and summary lines. Skipped files and warnings stay on `stderr`.

#### Import CLIProxyAPI (CPA) Tokens

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) stores tokens as flat JSON under `~/.cli-proxy-api/`. Import them directly without conversion:

```shell
codex-auth import --cpa                                  # scan default ~/.cli-proxy-api/*.json
codex-auth import --cpa /path/to/cpa-dir                 # scan a specific directory
codex-auth import --cpa /path/to/token.json --alias bob  # import a single CPA file
```

#### Fix Broken Account Data (Rebuild Registry)

If `codex-auth list` shows missing accounts or wrong usage data, the internal registry file may be out of sync with the actual auth files on disk. This command re-reads all auth files and rebuilds the registry from scratch:

```shell
codex-auth import --purge                                # rebuild from ~/.codex/accounts/*.auth.json
codex-auth import --purge /path/to/auth-exports          # rebuild from a specific folder
```

This does not import new files. It repairs the registry index for auth snapshots that already exist on disk.

### Show Status

```shell
codex-auth status
```

### Config

#### Auto-Switch

> [!WARNING]
> Auto-switch is experimental. Behavior, defaults, and platform integration may change in future releases while the feature matures.

Enable or disable:

```shell
codex-auth config auto enable
codex-auth config auto disable
```

`config auto enable` prints the current usage mode after installing the watcher, so you can immediately see whether auto-switch is running with default API-backed usage or local-only fallback semantics.

Adjust thresholds:

```shell
codex-auth config auto --5h 12
codex-auth config auto --5h 12 --weekly 8
codex-auth config auto --weekly 8
```

When auto-switching is enabled, a long-running background watcher refreshes the active account's usage and silently switches accounts when:

- 5h remaining drops below the configured 5h threshold (default `10%`), or
- weekly remaining drops below the configured weekly threshold (default `5%`)

The managed background worker is long-running on all supported platforms:

- Linux/WSL: persistent `systemd --user` service
- macOS: `LaunchAgent`
- Windows: scheduled task that launches the long-running helper at logon, restarts it after failures, has no 72-hour execution cap, and also starts it immediately on enable

#### Usage Refresh Source

API-backed fallback:

```shell
codex-auth config api enable
```

Local-only, no usage API calls:

```shell
codex-auth config api disable
```

Changing `config api` updates `registry.json` immediately. `api enable` is shown as API mode and `api disable` is shown as local mode.

## Q&A

### Why is my usage limit not refreshing?

If `codex-auth` is using local-only usage refresh, it reads the newest `~/.codex/sessions/**/rollout-*.jsonl` file. Recent Codex builds often write `token_count` events with `rate_limits: null`. The local files may still contain older usable usage limit data, but in practice they can lag by several hours, so local-only refresh may show a usage limit snapshot from hours ago instead of your latest state.

- Upstream Codex issue: [openai/codex#14880](https://github.com/openai/codex/issues/14880)

You can switch usage limit refresh to the usage API with:

```shell
codex-auth config api enable
```

Then confirm the current mode with:

```shell
codex-auth status
```

`status` should show `usage: api`.

Upgrade notes:

- If you are upgrading from `v0.1.x` to the latest `v0.2.x`, API usage refresh is enabled by default.
- If you previously used an early `v0.2` prerelease/test build and `status` still shows `usage: local`, run `codex-auth config api enable` once to switch back to API mode.

Verify with:

```shell
codex exec "say hello"
```

## Disclaimer

This project is provided as-is and use is at your own risk.

**Usage Data Refresh Source:**
`codex-auth` supports two sources for refreshing account usage/usage limit information:

1. **API (default):** When `config api enable` is on, the tool makes direct HTTPS requests to OpenAI's endpoints using your account's access token. This enables both usage refresh and team name refresh.
2. **Local-only:** When `config api disable` is on, the tool scans local `~/.codex/sessions/*/rollout-*.jsonl` files for usage data and skips team name refresh API calls. This mode is safer, but it can be less accurate because recent Codex rollout files often contain `rate_limits: null`, so the latest local usage limit data may lag by several hours.

**API Call Declaration:**
By enabling API(`codex-auth config api enable`), this tool will send your ChatGPT access token to OpenAI's servers, including `https://chatgpt.com/backend-api/wham/usage` for usage limit and `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27` for team name. This behavior may be detected by OpenAI and could violate their terms of service, potentially leading to account suspension or other risks. The decision to use this feature and any resulting consequences are entirely yours.
