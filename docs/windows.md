# Windows

## CLI output

Windows console hosts vary in how they handle UTF-8 text and ANSI escape
sequences. `codex-auth` keeps Windows CLI output conservative so PowerShell,
Windows Terminal, `cmd.exe`, and CI logs stay readable.

### Color

- Color is enabled only for TTY output.
- `NO_COLOR` disables color.
- On Windows, ANSI color is emitted only after
  `ENABLE_VIRTUAL_TERMINAL_PROCESSING` is already enabled or can be enabled for
  the target console handle.
- If virtual-terminal processing cannot be verified, output falls back to plain
  text with no ANSI escape sequences.

### Characters

- Windows-facing status markers must be ASCII by default.
- Do not use Unicode status glyphs such as check marks, warning signs, bullets,
  arrows, or box-drawing characters in Windows default output.
- Unicode may be used for non-Windows output when it is already part of an
  established command style.

Recommended Windows status markers:

```text
Codex App is already running, launch skipped.
- Checking latest https://github.com/Loongphy/codext release...
  Downloading Codext CLI for WSL (v0.3.0)
OK Downloaded Codext CLI for WSL (v0.3.0)
```

### Proxy

Windows keeps the user's proxy in the system (WinINET) settings and never puts it
into environment variables, while `curl` reads only environment variables. A
plain PowerShell, `pwsh`, or `cmd.exe` session therefore had no route to the API
and every usage column rendered `TimedOut`.

`codex-auth` now translates the system proxy into explicit curl options when no
proxy environment variable is set. See [api.md](./api.md#proxy) for the full
resolution order.

- Only the static system proxy is used. An automatic-configuration (PAC) URL is
  not evaluated; set `HTTPS_PROXY` or `CODEX_AUTH_PROXY` when a PAC is required.
- `CODEX_AUTH_PROXY=none` forces direct connections, which is the fastest way to
  confirm that a timeout is proxy-related.
- Proxy settings are read once per process, so changing the system proxy needs a
  new command.
- Running the Windows `codex-auth.exe` from WSL does not inherit Linux
  environment variables, and the Windows system proxy normally points at an
  address that is reachable from both sides. Prefer the Linux binary inside WSL
  and the Windows binary in a Windows shell.

## App command examples

Already running:

```text
Codex App is already running, launch skipped.
```

Launch with a managed CLI download:

```text
- Checking latest https://github.com/Loongphy/codext release...
  Downloading Codext CLI for WSL (v0.3.0)
  https://github.com/Loongphy/codext/releases/download/.../codext-linux-x64.tar.gz
OK Downloaded Codext CLI for WSL (v0.3.0)

- Environment Configuration ------------------------------------------------
  Platform: WSL (auto-detected)
  Codex Home: C:\Users\Loong\.codext (explicit)
  App ID: Loongphy.Codext (explicit)
  CLI Path: C:\Users\Loong\.codext\accounts\codext-cli\codex-linux-x64 (downloaded)
----------------------------------------------------------------------------
Launching Codex App...
```
