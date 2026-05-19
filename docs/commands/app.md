# `codex-auth app`

## Usage

```shell
codex-auth app [--app-path <path>] [--codex-cli-path <path>] [--codex-home <path>] [--platform win|wsl|mac]
```

## Behavior

Launches the official Codex App with per-process environment overrides.

- `codex-auth app` launches the app. There is no `launch` subcommand.
- `--app-path <path>` points to the App executable or an installed package/app directory.
- `--codex-cli-path <path>` is injected as `CODEX_CLI_PATH` for this launch. If it is omitted, `app` fetches the latest Loongphy codext release metadata, compares it with the managed cached CLI version, downloads only when the cached version differs or is missing, and uses that file; it does not reuse an existing `CODEX_CLI_PATH` from the current shell.
- `--codex-home <path>` is injected as `CODEX_HOME` for `app` launches and selects the accounts cache used for managed CLI resolution.
- `--platform win|wsl|mac` selects the app runtime platform:
  - `win` writes the Windows global setting so the app runs the agent natively.
  - `wsl` writes the Windows global setting so the app runs the agent inside WSL.
  - `mac` launches the macOS app directly and does not use the Windows WSL setting.
- `--std` starts the app executable directly with stdout/stderr attached to the current terminal. Use it for debugging app logs; normal launches stay quiet and use the platform GUI launcher.

If `--app-path` is omitted, `CODEX_AUTH_APP_PATH` is used when set; otherwise
the official installed app is auto-detected. On Windows this uses AppX package
lookup for `OpenAI.Codex`. On macOS it checks `/Applications/Codex.app` and
`~/Applications/Codex.app`; the latter is the standard per-user Applications
folder.

If `--platform` is omitted, Windows reads `$CODEX_HOME/.codex-global-state.json`
and uses `wsl` when `runCodexInWindowsSubsystemForLinux` is `true`; otherwise it
uses `win`. macOS defaults to `mac`.

Default downloaded CLIs are cached directly under:

```text
$CODEX_HOME/accounts/codext-cli/codex-<platform>
$CODEX_HOME/accounts/codext-cli/codex-<platform>.version
```

On Windows, the default download prepares both the Windows-native and WSL Linux
Loongphy codext assets for the current CPU architecture, such as `win32-x64`
and `linux-x64`. On macOS, it downloads only the matching macOS asset, such as
`darwin-x64` or `darwin-arm64`.

Windows App launching is handled by the Windows `codex-auth.exe` build. For the
auto-detected app, launch resolves the package AUMID and opens
`shell:AppsFolder\<AUMID>`. Use a Windows app path such as
`C:\Program Files\WindowsApps\...\app\Codex.exe` for `--app-path` only when an
explicit override is needed. The WSL build does not launch Windows App packages.

For Windows-native App launches, `--codex-cli-path` must point to something the Windows
App process can spawn. A WSL command name such as `codex-custom` is not a
Windows executable path.

For macOS App launches, the auto-detected app is opened with bundle identifier
`com.openai.codex`. `--app-path` may point to `/Applications/Codex.app` or the
app bundle path. Bundle paths are opened with `open`; direct executable paths
are not supported for app launch. The packaged macOS app normally uses
`Contents/Resources/codex` directly as its bundled CLI; setting
`--codex-cli-path` injects `CODEX_CLI_PATH` and takes precedence over that
bundled resource.
