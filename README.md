# Codex Auth

![command list](https://github.com/user-attachments/assets/6c13a2d6-f9da-47ea-8ec8-0394fc072d40)

`codex-auth` is a command-line tool for switching Codex accounts.

> [!IMPORTANT]
> For **Codex CLI** users, after switching accounts, you must fully exit `codex` (type `/exit` or close the terminal session) and start it again for the new account to take effect.
>
> If you want seamless automatic account switching without restarting `codex`, use forked [codext](https://github.com/Loongphy/codext), but you need to build it yourself because there is no prebuilt install method yet.

## Supported Platforms

`codex-auth` works with these Codex clients:

- Codex CLI
- VS Code extension
- Codex App

For the best experience, install the Codex CLI even if you mainly use the VS Code extension or the App, because it makes adding accounts easier:

```shell
npm install -g @openai/codex
```

After that, you can use `codex login` or `codex-auth login` to sign in and add accounts more easily.

## Install

Install with npm:

```shell
npm install -g @loongphy/codex-auth
```

  You can also run it without a global install:

```shell
npx @loongphy/codex-auth list
```

  npm packages currently support Linux x64, macOS x64, macOS arm64, and Windows x64.

> [!NOTE]
> Older Bash/PowerShell GitHub-release installs could leave a standalone `codex-auth` binary outside npm's install path.
> Those legacy installs can shadow the npm package or a local source build, so remove them during migration.

### Uninstall

Remove the npm package:

```shell
npm uninstall -g @loongphy/codex-auth
```

Remove old Bash-installer leftovers on Linux/macOS/WSL2:

```shell
rm -f ~/.local/bin/codex-auth
rm -f ~/.local/bin/codex-auth-auto
sed -i '/# Added by codex-auth installer/,+1d' ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc ~/.zprofile 2>/dev/null || true
```

If you used fish:

```shell
sed -i '/# Added by codex-auth installer/,+3d' ~/.config/fish/config.fish 2>/dev/null || true
```

Remove old PowerShell-installer leftovers on Windows:

```powershell
Remove-Item "$env:LOCALAPPDATA\codex-auth\bin\codex-auth.exe" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\codex-auth\bin\codex-auth-auto.exe" -Force -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable(
  "Path",
  (($env:Path -split ';' | Where-Object { $_ -and $_ -ne "$env:LOCALAPPDATA\codex-auth\bin" }) -join ';'),
  "User"
)
```

After cleanup, verify which binary is still active:

```shell
which codex-auth
codex-auth --version
```

## Commands

### Account Management

| Command | Description |
|---------|-------------|
| `codex-auth list` | List all accounts |
| `codex-auth login` | Run `codex login`, then add the current account |
| `codex-auth switch [<email>]` | Switch active account interactively or by partial match |
| `codex-auth remove` | Remove accounts with interactive multi-select |
| `codex-auth status` | Show auto-switch, service, and usage status |

> `codex-auth add` is still accepted as a deprecated alias for `codex-auth login`.

### Import

| Command | Description |
|---------|-------------|
| `codex-auth import <path> [--alias <alias>]` | Import a single file or batch import from a folder |
| `codex-auth import --cpa [<path>]` | Import [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) token JSON |
| `codex-auth import --purge [<path>]` | Rebuild `registry.json` from existing auth files |

### Configuration

| Command | Description |
|---------|-------------|
| `codex-auth config auto enable\|disable` | Enable or disable background auto-switching |
| `codex-auth config auto [--5h <%>] [--weekly <%>]` | Set auto-switch thresholds |
| `codex-auth config api enable\|disable` | Use API-backed fallback or local-only usage refresh |

---

## Examples

### List Accounts

```shell
codex-auth list
```

### Switch Account

Interactive: shows email, 5h, weekly, and last activity.

```shell
codex-auth switch
```

Before the picker opens, the current active account's usage is refreshed once so the selected row is not stale. The newly selected account is not refreshed after the switch completes.

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

Candidate selection follows the current watcher behavior:

- when `config api enable` is on, the watcher keeps a daemon-local in-memory candidate index, does bounded top-candidate upkeep in the background, and revalidates only the best few stale candidates before a switch
- in local-only mode, accounts without any usage snapshot are still treated as fresh candidates with full quota
- when the 5h trigger comes from an actual 300-minute window or an unlabeled primary window, free accounts use a stronger real-time 5h guard and switch no later than `35%` remaining even if the configured 5h threshold is lower
- free accounts that expose only a single `10080`-minute weekly window are still eligible auto-switch candidates; that weekly remaining percentage is used as their candidate score

The managed background worker is long-running on all supported platforms:

- Linux/WSL: persistent `systemd --user` service
- macOS: `LaunchAgent`
- Windows: scheduled task that launches the long-running helper at logon, restarts it after failures, has no 72-hour execution cap, and also starts it immediately on enable

The watcher checks local rollout usage roughly once per second and prefers local rollout events over API polling. In watch mode it caches the newest rollout file between bounded full rescans so large `~/.codex/sessions` trees are not re-walked every second. When `config api enable` is on, the usage API remains a slower fallback, active-account API cooldown resets when the active account changes, and candidate revalidation is driven by a daemon-local in-memory candidate index instead of batch-refreshing every account on every loop.

Successful foreground `codex-auth` commands also reconcile the managed auto-switch service, so a disabled config removes stale background units while an enabled background worker is refreshed onto the current binary after upgrades or service drift.

Changing thresholds updates `registry.json`, and the running watcher picks them up on the next polling cycle without a service restart.

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

Implementation details are documented in [`docs/auto-switch.md`](docs/auto-switch.md).

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

### How to import tokens from cli-proxy-api?

If you have token files from `~/.cli-proxy-api/token*.json`, this repository includes a helper script that can convert them into a format codex-auth can read.

The CLI can also import the flat cli-proxy-api / CPA JSON files directly:

```shell
codex-auth import --cpa                  # default source: ~/.cli-proxy-api
codex-auth import --cpa /path/to/cpa-dir # scans direct child .json files
```

Each CPA file is converted in memory to the standard auth snapshot shape before it is written into `~/.codex/accounts/`. Missing or empty `refresh_token` values are skipped as `MissingRefreshToken`.

The script is not bundled in the published npm package, so run it from a clone of this repository:

```shell
# Convert: ~/.cli-proxy-api → /tmp/tokens
python3 scripts/convert_tokens.sh

# Or specify custom directories
python3 scripts/convert_tokens.sh <source_dir> <output_dir>
```

Then import and switch:

```shell
codex-auth import /tmp/tokens/
# or import the CPA files directly without a conversion step
codex-auth import --cpa
codex-auth switch
```

Verify with:

```shell
codex exec "say hello"
```

> **Output format:** Each converted file contains `auth_mode`, `OPENAI_API_KEY`, `tokens` (with `id_token`, `access_token`, `refresh_token`, `account_id`), and `last_refresh`. The `refresh_token` field is required for token refresh to work.

## Disclaimer

This project is provided as-is and use is at your own risk.

**Usage Data Refresh Source:**
`codex-auth` supports two sources for refreshing account usage/usage limit information:

1. **API (default):** When `config api enable` is on, the tool makes direct HTTPS requests to OpenAI's endpoints using your account's access token. This is the current default mode.
2. **Local-only:** When `config api disable` is on, the tool scans local `~/.codex/sessions/*/rollout-*.jsonl` files without making API calls. This mode is safer, but it can be less accurate because recent Codex rollout files often contain `rate_limits: null`, so the latest local usage limit data may lag by several hours.

**API Call Declaration:**
By enabling API-based usage refresh, this tool will send your ChatGPT access token to OpenAI's servers (specifically `https://chatgpt.com/backend-api/wham/usage`) to fetch current quota information. This behavior may be detected by OpenAI and could violate their terms of service, potentially leading to account suspension or other risks. The decision to use this feature and any resulting consequences are entirely yours.
