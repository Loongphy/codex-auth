# `codex-auth app`

## Usage

```shell
codex-auth app [--app-path <path>] [--codex-cli-path <path>] [--codex-home <path>] [--platform win|wsl|mac]
```

## Behavior

Launches the official Codex App with per-process environment overrides.

- `codex-auth app` launches the app. There is no `launch` subcommand.
- If the Codex App is already running, `app` prints that status and exits before
  resolving or downloading the managed CLI.
- `--app-path <path>` points to the App executable or an installed package/app directory. Explicit and environment-provided app paths must exist before launch planning starts.
- `--codex-cli-path <path>` is injected as `CODEX_CLI_PATH` for this launch. Explicit CLI paths must exist. If it is omitted, `app` fetches the latest [`Loongphy/codext`](https://github.com/Loongphy/codext) release metadata, compares it with the managed cached CLI version for the selected platform, downloads only when the cached version differs or is missing, and uses that file; it does not reuse an existing `CODEX_CLI_PATH` from the current shell.
- `--codex-home <path>` is injected as `CODEX_HOME` for `app` launches and selects the accounts cache used for managed CLI resolution.
- `--platform win|wsl|mac` selects the app runtime platform:
  - `win` writes the Windows global setting so the app runs the agent natively.
  - `wsl` writes the Windows global setting so the app runs the agent inside WSL.
  - `mac` launches the macOS app directly and does not use the Windows WSL setting.
- `--std` starts the app executable directly with stdout/stderr attached to the current terminal. Use it for debugging app logs; normal launches stay quiet and use the platform GUI launcher.

`app` prints its launch plan and managed CLI resolution to stderr before
starting the GUI launcher. Example output:

```text
Codex App is already running, launch skipped.
```

When the app is not already running, the output continues with launch planning:

```text
- Checking latest https://github.com/Loongphy/codext release...
  Downloading Codext CLI for WSL (v0.3.0)
  https://github.com/Loongphy/codext/releases/download/.../codext-linux-x64.tar.gz
OK Downloaded Codext CLI for WSL (v0.3.0)

- Environment Configuration ------------------------------------------------
  Platform: WSL (auto-detected)
  Codex Home: C:\Users\Alice\.codext (explicit)
  App Path: C:\Program Files\WindowsApps\OpenAI.Codext_...\app (explicit)
  CLI Path: C:\Users\Alice\.codext\accounts\codext-cli\codex-linux-x64 (downloaded)
----------------------------------------------------------------------------
Launching Codex App...
```

See [Windows](../windows.md) for Windows console color and character rules.

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

The default download prepares only the selected platform's
[`Loongphy/codext`](https://github.com/Loongphy/codext) asset for the current
CPU architecture, such as `win32-x64`, `linux-x64`, `darwin-x64`, or
`darwin-arm64`.

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
