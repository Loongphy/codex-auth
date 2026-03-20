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

## Commands

### Account Management

| Command | Description |
|---------|-------------|
| `codex-auth list` | List all accounts |
| `codex-auth login` | Run `codex login`, then add the current account |
| `codex-auth switch [<email>]` | Switch active account (interactive or partial match) |
| `codex-auth remove` | Remove accounts (interactive multi-select) |
| `codex-auth status` | Show auto-switch / usage status |

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
| `codex-auth config auto [--interval <duration>] [--5h <%>] [--weekly <%>]` | Set polling interval and usage thresholds |
| `codex-auth config api enable\|disable` | Use API-only or local-only usage refresh |

---

## Examples

### List Accounts

```shell
codex-auth list
```

### Switch Account

Interactive — shows email, 5h, weekly, last activity:

```shell
codex-auth switch
```

Before the picker opens, the current active account's usage is refreshed once so the selected row is not stale. The newly selected account is not refreshed after the switch completes.

![command switch](https://github.com/user-attachments/assets/48a86acf-2a6e-4206-a8c4-591989fdc0df)

Non-interactive — fuzzy match by email or alias:

```shell
codex-auth switch john             # match any account containing "john"
codex-auth switch john@gmail.com   # match by full or partial email
codex-auth switch work             # match by alias (set via --alias during import, shown in `codex-auth list`)
```

If the keyword matches multiple accounts (e.g. the same email under different teams), the command falls back to interactive selection. For same-account multi-team setups, use `codex-auth switch` directly.

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

![command import --alias](https://github.com/user-attachments/assets/420b0a2d-fd33-449f-b4a1-820f01031e7d)

`--alias` sets a display name for the account. It appears in `codex-auth list` (e.g. `(personal)user@gmail.com`) and can be used with `codex-auth switch <alias>` for quick switching.

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

#### Import CLIProxyAPI (CPA) Tokens

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) stores tokens as flat JSON under `~/.cli-proxy-api/`. Import them directly without conversion:

```shell
codex-auth import --cpa                                  # scan default ~/.cli-proxy-api/*.json
codex-auth import --cpa /path/to/cpa-dir                 # scan a specific directory
codex-auth import --cpa /path/to/token.json --alias bob  # import a single CPA file
```

#### Fix Broken Account Data (Rebuild Registry)

If `codex-auth list` shows errors, missing accounts, or wrong usage data, the internal registry file (`registry.json`) may be out of sync with the actual auth files on disk. This command re-reads all auth files and rebuilds the registry from scratch:

```shell
codex-auth import --purge                                # rebuild from ~/.codex/accounts/*.auth.json
codex-auth import --purge /path/to/auth-exports          # rebuild from a specific folder
```

> This does not import new files — it only repairs the registry index for files that already exist in `~/.codex/accounts/`.

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

All parameters can be combined in a single command:

```shell
codex-auth config auto [--interval <duration>] [--5h <percent>] [--weekly <percent>]
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--interval <duration>` | How often the background worker checks usage and decides whether to switch. Accepts a number with suffix: `s` (seconds), `m` (minutes), `h` (hours). | `1m` |
| `--5h <percent>` | When 5-hour remaining usage drops below this percentage, auto-switch is triggered to the next available account. | `10` |
| `--weekly <percent>` | When weekly remaining usage drops below this percentage, auto-switch is triggered to the next available account. | `5` |

Examples:

```shell
# Set polling interval to 4 seconds
codex-auth config auto --interval 4s

# Set interval to 4 minutes and customize thresholds
codex-auth config auto --interval 4m --5h 12 --weekly 8

# Set interval to 4 hours
codex-auth config auto --interval 4h

# Only adjust the 5h threshold, keep other settings
codex-auth config auto --5h 15
```

> On Windows, intervals below `1m` are clamped up to `1m` with a warning.

#### Usage Refresh Source

API-only (default) — makes HTTPS requests to OpenAI:

```shell
codex-auth config api enable
```

Local-only — reads local session files, no API calls:

```shell
codex-auth config api disable
```

When auto-switching is enabled, a background worker checks usage at the configured interval and switches to the next account when:

- 5h remaining drops below the `--5h` threshold (default `10%`), or
- weekly remaining drops below the `--weekly` threshold (default `5%`)

Accounts that have never been used are treated as having full quota.

Changing thresholds or the `config api` source takes effect immediately on the next check. Changing the interval takes effect on the next polling cycle. You can verify the current state with:

```shell
codex-auth status
codex-auth help
```

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
- If you previously used an early `v0.2` prerelease/test build and `status` still shows `usage: local`, run `codex-auth config api enable` once to switch to API mode.

### How to import tokens from CLIProxyAPI?

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) stores tokens as flat JSON files under `~/.cli-proxy-api/`. You can import them directly:

```shell
codex-auth import --cpa                          # default source: ~/.cli-proxy-api
codex-auth import --cpa /path/to/cpa-dir         # scan a specific directory
codex-auth import --cpa /path/to/token.json --alias myaccount  # import a single file
```

Each CPA file is converted in memory to the standard auth snapshot shape before it is written into `~/.codex/accounts/`. Missing or empty `refresh_token` values are skipped.

Then switch to the imported account:

```shell
codex-auth switch
```

Verify with:

```shell
codex exec "say hello"
```

## Disclaimer

This project is provided as-is and use is at your own risk.

**Usage Data Refresh Source:**
`codex-auth` supports two sources for refreshing account usage/usage limit information:

1. **API (default):** When `config api enable` is on, the tool makes direct HTTPS requests to OpenAI's endpoints using your account's access token. This is the current default mode.
2. **Local-only:** When `config api disable` is on, the tool scans local `~/.codex/sessions/*/rollout-*.jsonl` files without making API calls. This mode is safer, but it can be less accurate because recent Codex rollout files often contain `rate_limits: null`, so the latest local usage limit data may lag by several hours.

**API Call Declaration:**
By enabling API-based usage refresh, this tool will send your ChatGPT access token to OpenAI's servers (specifically `https://chatgpt.com/backend-api/wham/usage`) to fetch current quota information. This behavior may be detected by OpenAI and could violate their terms of service, potentially leading to account suspension or other risks. The decision to use this feature and any resulting consequences are entirely yours.
