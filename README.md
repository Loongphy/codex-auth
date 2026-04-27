# Codex Auth [![latest release](https://img.shields.io/github/v/release/Loongphy/codex-auth?sort=semver&label=latest)](https://github.com/Loongphy/codex-auth/releases/latest) [![latest pre-release](https://img.shields.io/github/v/release/Loongphy/codex-auth?include_prereleases&sort=semver&filter=*-*&label=pre-release)](https://github.com/Loongphy/codex-auth/releases)

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

### Uninstall

#### npm

Remove the npm package:

```shell
npm uninstall -g @loongphy/codex-auth
```

## Commands

Detailed command documentation lives in [docs/commands/README.md](./docs/commands/README.md).

### Account Management

| Command | Description |
|---------|-------------|
| [`codex-auth list [--live] [--api\|--skip-api]`](./docs/commands/list.md) | List stored accounts and usage state |
| [`codex-auth login [--device-auth]`](./docs/commands/login.md) | Run `codex login`, then add the current account |
| [`codex-auth switch [--live] [--api\|--skip-api]`](./docs/commands/switch.md) | Switch the active account interactively |
| [`codex-auth switch <query>`](./docs/commands/switch.md) | Switch directly by row number or account selector |
| [`codex-auth remove [--live] [--api\|--skip-api]`](./docs/commands/remove.md) | Remove accounts interactively |
| [`codex-auth remove <query> [<query>...]`](./docs/commands/remove.md) | Remove accounts by selector |
| [`codex-auth remove --all`](./docs/commands/remove.md) | Remove all stored accounts |
| [`codex-auth status`](./docs/commands/status.md) | Show auto-switch, service, and usage status |

### Import and Maintenance

| Command | Description |
|---------|-------------|
| [`codex-auth import <path> [--alias <alias>]`](./docs/commands/import.md) | Import a single auth file or batch import a folder |
| [`codex-auth import --cpa [<path>]`](./docs/commands/import.md) | Import CLIProxyAPI token JSON |
| [`codex-auth import --purge [<path>]`](./docs/commands/import.md) | Rebuild `registry.json` from auth files |
| [`codex-auth clean`](./docs/commands/clean.md) | Delete managed backup and stale account files |

### Configuration

| Command | Description |
|---------|-------------|
| [`codex-auth config auto enable\|disable`](./docs/commands/config.md) | Enable or disable background auto-switching |
| [`codex-auth config auto --5h <percent> [--weekly <percent>]`](./docs/commands/config.md) | Configure background auto-switch thresholds |
| [`codex-auth config api enable\|disable`](./docs/commands/config.md) | Enable or disable default API-backed refresh |

## Quick Examples

```shell
codex-auth list
codex-auth switch
codex-auth switch 02
codex-auth remove work
codex-auth import /path/to/auth.json --alias personal
codex-auth config api disable
codex-auth status
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

Verify with:

```shell
codex exec "say hello"
```

## Disclaimer

This project is provided as-is and use is at your own risk.

**Usage Data Refresh Source:**
`codex-auth` supports two sources for refreshing account usage/usage limit information:

1. **API (default):** When `config api enable` is on, the tool makes direct HTTPS requests to OpenAI's endpoints using your account's access token. This enables both usage refresh and team name refresh. npm installs already satisfy the runtime requirement.
2. **Local-only:** When `config api disable` is on, the tool scans local `~/.codex/sessions/*/rollout-*.jsonl` files for usage data and skips team name refresh API calls. This mode is safer, but it can be less accurate because recent Codex rollout files often contain `rate_limits: null`, so the latest local usage limit data may lag by several hours.

**API Call Declaration:**
By enabling API(`codex-auth config api enable`), this tool will send your ChatGPT access token to OpenAI's servers, including `https://chatgpt.com/backend-api/wham/usage` for usage limit and `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27` for team name. This behavior may be detected by OpenAI and could violate their terms of service, potentially leading to account suspension or other risks. The decision to use this feature and any resulting consequences are entirely yours.
