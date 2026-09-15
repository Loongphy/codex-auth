# Changelog

## v0.3.0

This release is a major rework since `v0.2.x`: the experimental background auto-switch is gone,
replaced by a foreground **live TUI + explicit commands** model, with new Codex App support,
JSON output, and several new account management commands.

### ✨ Highlights

**Live TUI**

- `list --live`, `switch --live`, `remove --live`: continuously refreshing table views with mouse-wheel scrolling and a copy-friendly layout.
- `config live --interval <5-3600>`: configure the live refresh interval (default `60s`).
- `list --active`: refresh only the active account for a fast result.

**New commands**

- `codex-auth app` (experimental): injects the managed `codext` CLI through `CODEX_CLI_PATH` so the **Codex App can switch accounts without a restart** — new chats, resumed conversations, and continued conversations.
- `codex-auth export [<dir>]` / `export --cpa`: export stored auth snapshots or CLIProxyAPI token JSON.
- `codex-auth alias set|clear <query> [<alias>]`: set or clear an account alias.
- `codex-auth clean`: prune managed backups and stale snapshots; `clean background` removes background registrations left by older versions.

**Account selection and switching**

- `codex-auth -` and `switch -` jump back to the previous active account.
- Selectors are unified across commands: alias, email, display number, or partial query. `remove` accepts multiple selectors and `--all`.
- Support for **API key accounts** and phone-login organization accounts.

**API and data**

- `--api` / `--skip-api` control remote refresh per command (API-backed refresh is the default), replacing the global `config api` toggle.
- `list` shows a `RESET CREDITS` column.
- **`--json`** for `list`, `switch <query>`, and `remove` emits one machine-readable document under a `schema_version: 1` compatibility contract — suitable for building a GUI on top. See [docs/json-api.md](./docs/json-api.md).

**Import**

- Supports JSON array imports; CPA auth field handling is normalized.

### 💥 Breaking Changes

- **Background auto-switch removed.** `config auto enable|disable`, the threshold options, the systemd / LaunchAgent / scheduled-task services, and the `codex-auth-auto` binary are all gone. The tool now runs in the foreground only. Clean up old registrations with `codex-auth clean background`.
- **`codex-auth status` removed**, along with the global `config api` toggle — use per-command `--api` / `--skip-api`.
- **`list --debug` removed.**
- **`registry.json` moves to `schema_version = 4`** (migrated automatically from `3`). To downgrade to `v0.2.x`, manually set `"schema_version": 3`.
- **Plan naming semantics changed**: legacy `team` becomes `business`, legacy `business` becomes `enterprise`.
- **Node.js is no longer required.** All API requests go through `curl`, which must be available on `PATH`. Proxy settings are handled by curl's own environment variables.

### 🐛 Fixes and Improvements

- Windows: fixed Codex launcher resolution (`.cmd`, `.bat`, PowerShell wrappers), bypassed the PowerShell script policy for the `.ps1` fallback, hid API child-process windows, and fixed list colors in Windows terminals.
- Login runs in an isolated scratch `CODEX_HOME` and syncs the active auth beforehand, so existing credentials are not disturbed.
- Credential files and account directories are created with restrictive (`0600`-style) permissions.
- Removed browser user-agent spoofing for ChatGPT API requests in favor of a `codex-auth` user agent.
- Upgraded to Zig 0.16.0; clearer usage error codes and registry version errors.

### 📖 Documentation

Added per-command documentation under [docs/commands/](./docs/commands/README.md), plus
[docs/json-api.md](./docs/json-api.md), [docs/api.md](./docs/api.md),
[docs/schema-migration.md](./docs/schema-migration.md), and
[docs/table-layout.md](./docs/table-layout.md).
