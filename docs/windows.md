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

### App command examples

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

### Reset credits rail examples

The `list --live` reset credits rail is borderless on every platform. It nests
under its account row by indentation, uses an uppercase heading, and relies on
the footer for the key hints. The same state on both platforms, with the rail
indented four columns under its account row:

Non-Windows:

```text
    RESETS · 2 available
    > Full reset (Weekly + 5 hr) · 11-01 08:00 · in 9d · Enter again to redeem
      untitled
    ✓ reset credit redeemed
```

Windows:

```text
    RESETS, 2 available
    > Full reset (Weekly + 5 hr), 11-01 08:00, in 9d, Enter again to redeem
      untitled
    OK reset credit redeemed
```

A failure line carries no marker on Windows, because its sentence already says
what happened: `redeem failed (HTTP 500)`, or `reset credit is no longer available;
refresh to see current resets`.

`codex-auth reset` prints the same separator difference outside the TUI.

Non-Windows:

```text
reset credit redeemed · 1 left (next exp 01-01 08:00)
```

Windows:

```text
reset credit redeemed, 1 left (next exp 01-01 08:00)
```
