# `codex-auth app`

## Usage

```shell
codex-auth app [--id <id>] [--codex-cli-path <path>] [--codex-home <path>] [--platform win|wsl|mac]
```

## Behavior

Launches the official Codex App with per-process environment overrides.

- `codex-auth app` launches the app. There is no `launch` subcommand.
- If the Codex App is already running, `app` prints that status and exits before
  resolving or downloading the managed CLI.
- `--id <id>` selects the packaged app to launch. On Windows it accepts an
  AppX/MSIX package name such as `OpenAI.Codex` or `Loongphy.Codext`, or a full
  AUMID. On macOS it accepts a bundle identifier such as `com.openai.codex`.
- If `--id` is omitted, the default is `OpenAI.Codex` on Windows and
  `com.openai.codex` on macOS.
- `--codex-cli-path <path>` is injected as `CODEX_CLI_PATH` for this launch. Explicit CLI paths must exist. If it is omitted, `app` fetches the latest [`Loongphy/codext`](https://github.com/Loongphy/codext) release metadata, compares it with the managed cached CLI version for the selected platform, downloads only when the cached version differs or is missing, and uses that file; it does not reuse an existing `CODEX_CLI_PATH` from the current shell.
- `--codex-home <path>` is injected as `CODEX_HOME` for `app` launches and selects the accounts cache used for managed CLI resolution.
- `--platform win|wsl|mac` selects the app runtime platform:
  - `win` writes the Windows desktop setting so the app runs the agent natively and selects the Windows managed CLI.
  - `wsl` writes the Windows desktop setting so the app runs the agent inside WSL and selects the Linux managed CLI.
  - `mac` launches the macOS app directly.
- `--std` resolves the packaged app executable, then starts it with stdout/stderr attached to the current terminal. Use it for debugging app logs; normal launches stay quiet and use the platform GUI launcher.

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
  App ID: Loongphy.Codext (explicit)
  CLI Path: C:\Users\Alice\.codext\accounts\codext-cli\codex-linux-x64 (downloaded)
----------------------------------------------------------------------------
Launching Codex App...
```

See [Windows](../windows.md) for Windows console color and character rules.

If `--platform` is omitted, Windows reads
`$CODEX_HOME/config.toml` and uses `wsl` when
`[desktop].runCodexInWindowsSubsystemForLinux` is `true`; otherwise it uses
`win`. macOS defaults to `mac`. Explicit `--platform win|wsl` updates that same
desktop setting before launch.

Default downloaded CLIs are cached directly under:

```text
$CODEX_HOME/accounts/codext-cli/codex-<platform>
$CODEX_HOME/accounts/codext-cli/codex-<platform>.version
```

The default download prepares only the selected platform's
[`Loongphy/codext`](https://github.com/Loongphy/codext) asset for the current
CPU architecture, such as `win32-x64`, `linux-x64`, `darwin-x64`, or
`darwin-arm64`.

Windows App launching is handled by the Windows `codex-auth.exe` build. Normal
launch resolves the package name or AUMID and opens `shell:AppsFolder\<AUMID>`.
The WSL build does not launch Windows App packages.

For Windows-native App launches, `--codex-cli-path` must point to something the Windows
App process can spawn. A WSL command name such as `codex-custom` is not a
Windows executable path.

For macOS App launches, the app is opened with its bundle identifier. The
packaged macOS app normally uses `Contents/Resources/codex` directly as its
bundled CLI; setting `--codex-cli-path` injects `CODEX_CLI_PATH` and takes
precedence over that bundled resource.

## Validation Errors

App launch validation reports every configured option issue it can detect
before printing the launch plan. New option validation should follow this
format:

```text
ERROR: --id: App ID does not exist
        "OpenAI.Codex"

ERROR: --codex-cli-path: Path does not exist
        "C:\Program Files\WindowsApps\OpenAI.Codext_26.519.2081.0_x64__fzsqvsr4xv3kw\app\Codex.exe"
```
