# `codex-auth app`

## Usage

```shell
codex-auth app [--app-path <path>] [--cli-path <path>] [--home <path>] [--platform win|wsl|mac]
codex-auth app status [--app-path <path>] [--cli-path <path>] [--home <path>] [--platform win|wsl|mac]
```

## Behavior

Launches the official Codex App with per-process environment overrides.

- `codex-auth app` launches the app. There is no `launch` subcommand.
- `codex-auth app status` prints the effective defaults without downloading the CLI or launching the app.
- `--app-path <path>` points to the App executable or an installed package/app directory.
- `--cli-path <path>` is injected as `CODEX_CLI_PATH` for this launch. If it is omitted, `CODEX_CLI_PATH` is reused when set; otherwise launch downloads the latest Loongphy codext release into the accounts cache and uses that cached binary.
- `--home <path>` is injected as `CODEX_HOME` for this launch.
- `--platform win|wsl|mac` selects the app runtime platform:
  - `win` writes the Windows global setting so the app runs the agent natively.
  - `wsl` writes the Windows global setting so the app runs the agent inside WSL.
  - `mac` launches the macOS app directly and does not use the Windows WSL setting.
- `--dry-run` prints the effective launch environment without starting the app.
- `--wait` waits for the launched process to exit.
- `-- <args>` passes remaining arguments to the app executable on non-Windows platforms.

If `--app-path` is omitted, `CODEX_AUTH_APP_PATH` is used when set; otherwise
the official installed app is auto-detected. On Windows this uses AppX package
lookup for `OpenAI.Codex` and resolves the package executable. On macOS it
checks `/Applications/Codex.app` and `~/Applications/Codex.app`; the latter is
the standard per-user Applications folder.

If `--platform` is omitted, Windows reads `$CODEX_HOME/.codex-global-state.json`
and uses `wsl` when `runCodexInWindowsSubsystemForLinux` is `true`; otherwise it
uses `win`. macOS defaults to `mac`.

Default downloaded CLIs are cached under:

```text
$CODEX_HOME/accounts/codext-cli/<release-tag>/<platform>/codex
```

On Windows, the default download prepares both the Windows-native and WSL Linux
Loongphy codext assets for the current CPU architecture, such as `win32-x64`
and `linux-x64`. On macOS, it downloads only the matching macOS asset, such as
`darwin-x64` or `darwin-arm64`.

Windows App launching is handled by the Windows `codex-auth.exe` build. Use a
Windows app path such as `C:\Program Files\WindowsApps\...\app\Codex.exe` for
`--app-path`. The WSL build does not patch or launch Windows App packages.

For Windows-native App launches, `--cli-path` must point to something the Windows
App process can spawn. A WSL command name such as `codex-custom` is not a
Windows executable path.

For macOS App launches, `--app-path` may point to `/Applications/Codex.app` or
the app executable inside `Contents/MacOS`. The packaged macOS app normally uses
`Contents/Resources/codex` directly as its bundled CLI; setting `--cli-path`
injects `CODEX_CLI_PATH` and takes precedence over that bundled resource.

The Electron app currently appends `--analytics-default-enabled` when it starts
`app-server`. A plain `CODEX_CLI_PATH` override changes which binary is executed
but does not remove that argument. To suppress it at launch time, point
`--cli-path` at a wrapper/shim that filters that argument before execing the real
codext binary.
