# `codex-auth app`

## Usage

```shell
codex-auth app [--app-path <path>] [--cli-path <path>] [--home <path>] [--platform win|wsl|mac]
codex-auth app status [--app-path <path>] [--cli-path <path>] [--home <path>] [--platform win|wsl|mac]
codex-auth app patch [--cli-path <path>] [--home <path>] [--platform win|wsl|mac]
codex-auth app unpatch
```

## Behavior

Launches the official Codex App with per-process environment overrides, or
installs a persistent CLI override for normal app launches.

- `codex-auth app` launches the app. There is no `launch` subcommand.
- `codex-auth app status` prints the effective defaults without downloading the CLI or launching the app.
- `codex-auth app patch` writes a user-level persistent `CODEX_CLI_PATH` patch. After Codex App is fully restarted, normal launches from the Start menu, Finder, or Dock go through a generated guarded shim without running `codex-auth app` each time.
- `codex-auth app unpatch` removes the persistent `CODEX_CLI_PATH` patch.
- `--app-path <path>` points to the App executable or an installed package/app directory.
- `--cli-path <path>` is injected as `CODEX_CLI_PATH` for this launch or used as the guarded target for `app patch`. If it is omitted, the command uses the managed cached/latest Loongphy codext CLI; it does not reuse an existing `CODEX_CLI_PATH` from the current shell.
- `--home <path>` is injected as `CODEX_HOME` for `app` launches. For `app patch`, it selects the accounts cache and the Windows platform-state file that are prepared before persisting `CODEX_CLI_PATH`; it does not persist `CODEX_HOME`.
- `--platform win|wsl|mac` selects the app runtime platform:
  - `win` writes the Windows global setting so the app runs the agent natively.
  - `wsl` writes the Windows global setting so the app runs the agent inside WSL.
  - `mac` launches the macOS app directly and does not use the Windows WSL setting.
- `--dry-run` prints the effective launch environment without starting the app.
- `--wait` waits for the launched process to exit and keeps its stdout/stderr attached. Without `--wait`, `app` starts the GUI app quietly and detaches from terminal output.
- `-- <args>` passes remaining arguments to the app executable on non-Windows platforms.

If `--app-path` is omitted, `CODEX_AUTH_APP_PATH` is used when set; otherwise
the official installed app is auto-detected. On Windows this uses AppX package
lookup for `OpenAI.Codex` and resolves the package executable. On macOS it
checks `/Applications/Codex.app` and `~/Applications/Codex.app`; the latter is
the standard per-user Applications folder.

If `--platform` is omitted, Windows reads `$CODEX_HOME/.codex-global-state.json`
and uses `wsl` when `runCodexInWindowsSubsystemForLinux` is `true`; otherwise it
uses `win`. macOS defaults to `mac`.

`app patch` uses the same platform resolution and writes the same Windows
setting before persisting `CODEX_CLI_PATH`, so the selected backend keeps using
the matching native Windows or Linux codext binary while the installed app
version still matches the patch.

Default downloaded CLIs are cached under:

```text
$CODEX_HOME/accounts/codext-cli/codex-<platform>
```

On Windows, the default download prepares both the Windows-native and WSL Linux
Loongphy codext assets for the current CPU architecture, such as `win32-x64`
and `linux-x64`. On macOS, it downloads only the matching macOS asset, such as
`darwin-x64` or `darwin-arm64`.

Windows App launching is handled by the Windows `codex-auth.exe` build. Use a
Windows app path such as `C:\Program Files\WindowsApps\...\app\Codex.exe` for
`--app-path`. The WSL build does not patch or launch Windows App packages.

On Windows, `app patch` writes the user environment variable with
`[Environment]::SetEnvironmentVariable(..., 'User')` and broadcasts an
environment change. The value points to a generated guarded shim under
`$CODEX_HOME/accounts/codext-cli/app-patch/<platform>/`, not directly to the
codext binary. Existing Codex App processes must still be closed; some
already-running parent processes may require a fresh Explorer session, sign-out,
or reboot before Start-menu launches inherit the updated variable.

On macOS, `app patch` sets the current `launchctl` GUI-session environment and
installs `~/Library/LaunchAgents/com.codex-auth.app-env.plist` so the variable is
restored at login. The LaunchAgent also points at a generated guarded shim.
`app unpatch` unloads and removes that LaunchAgent.

This is only needed for persistent GUI launches from Finder, Dock, Spotlight, or
login-restored sessions. One-shot `codex-auth app` launches do not need the
LaunchAgent; they pass the resolved `CODEX_CLI_PATH` directly to the launched
process.

The guarded shim is version-bound:

- Windows MSIX/AppX patches are tied to the package install path, which includes
  the AppX package version.
- WSL patches use the same package-root guard after Windows paths are converted
  to WSL paths.
- macOS patches are tied to the app bundle's `CFBundleVersion`.

If the app updates or a different Codex-family app inherits the same user-level
`CODEX_CLI_PATH`, the shim does not continue using the patched codext binary. It
falls back to the bundled/default CLI for that app where available, so a new app
version requires running `codex-auth app patch` again.

This follows the same durable-hook idea as app-bundle patchers, but it uses the
official `CODEX_CLI_PATH` hook instead of editing the app package. That avoids
MSIX/AppX package-integrity and install-directory permission problems on
Windows while still making normal app launches use the replacement CLI.

For Windows-native App launches, `--cli-path` must point to something the Windows
App process can spawn. A WSL command name such as `codex-custom` is not a
Windows executable path.

For macOS App launches, `--app-path` may point to `/Applications/Codex.app` or
the app executable inside `Contents/MacOS`. The packaged macOS app normally uses
`Contents/Resources/codex` directly as its bundled CLI; setting `--cli-path`
injects `CODEX_CLI_PATH` and takes precedence over that bundled resource.

The Electron app currently appends `--analytics-default-enabled` when it starts
`app-server`. The `CODEX_CLI_PATH` override changes which binary is executed but
does not remove that argument. To suppress it at launch time, point `--cli-path`
at a wrapper/shim that filters that argument before execing the real codext
binary; `app patch` will still wrap that path in its own version guard.
