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

## Full Commands

```shell
codex-auth list # list all accounts
codex-auth login # run `codex login`, then add the current account
codex-auth switch [<email>] # switch active account (interactive or partial/fragment match)
codex-auth import <path> [--alias <alias>] # smart import: file -> single import, folder -> batch import
codex-auth import --cpa [<path>] # import CPA flat token JSON from one file or directory
codex-auth import --purge [<path>] # rebuild registry.json from auth files for the current version
codex-auth remove [<query>|--all] # remove accounts
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

Import CPA exports directly:

```shell
codex-auth import --cpa                  # scan ~/.cli-proxy-api/*.json
codex-auth import --cpa /path/to/cpa-dir
codex-auth import --cpa /path/to/cpa.json --alias personal
```

Typical batch import output:

```text
Scanning /path/to/auth-exports...
  ✓ imported  token_ryan.taylor.alpha@email.com
  ✓ updated   token_jane.smith.alpha@email.com
  ✗ skipped   token_invalid: MalformedJson
Import Summary: 1 imported, 1 updated, 1 skipped (total 3 files)
```

`stdout` carries scanning/success/summary lines. Skipped files and warnings stay on `stderr`.

Rebuild `registry.json` from imported auth files:

```shell
codex-auth import --purge /path/to/auth-exports
codex-auth import --purge                  # rebuild from ~/.codex/accounts/*.auth.json
```

Switch accounts (interactive list shows email, 5h, weekly, last activity):

```shell
codex-auth switch               # arrow + number input, q to quit
```

Before the switch picker opens, `codex-auth switch` refreshes the current active account's usage once so the currently selected row is not stale. It does not refresh the newly selected account after the switch completes.

![command switch](https://github.com/user-attachments/assets/48a86acf-2a6e-4206-a8c4-591989fdc0df)

Switch account non-interactively (for scripts/other CLIs):

```shell
codex-auth switch user
```

If multiple accounts match, interactive selection is shown, and you can press `q` to quit without switching.

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
