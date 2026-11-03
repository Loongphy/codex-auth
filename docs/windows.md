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
indented four columns under its account row — the consumed card stays as a
struck-through, dimmed line tagged `redeemed`, which is drawn in success green
outside the strike:

Non-Windows:

```text
    RESETS · 1 available
    Full reset (Weekly + 5 hr) · 11-01 08:00 · in 9d redeemed
    > untitled
```

Windows:

```text
    RESETS, 1 available
    Full reset (Weekly + 5 hr), 11-01 08:00, in 9d redeemed
    > untitled
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

## System proxy

`curl` only discovers proxies from its own environment variables, so the system
proxy that a browser or `Invoke-WebRequest` honours was previously invisible to
API refresh. `codex-auth` reads it through WinHTTP and passes it to the curl
child process explicitly.

- The static proxy comes from `WinHttpGetIEProxyConfigForCurrentUser`, which
  already accounts for `ProxyEnable`, so a disabled entry is not mistaken for a
  configured one.
- An explicit auto-config URL is resolved per request by `WinHttpGetProxyForUrl`,
  which evaluates the PAC script in-process.
- WPAD auto-detection is deliberately not requested. It probes DHCP and DNS and
  can stall for seconds on a network with no WPAD server, and local forwarders
  such as mihomo do not rely on it.
- `ProxyOverride` becomes curl's `noproxy` option, with `<local>` mapped to
  `localhost`.
- An existing `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` still wins, so nothing
  changes for a shell that already exports them. To force a direct connection,
  set `NO_PROXY=*`.

The same translation applies to the Codext release lookup and download in
`codex-auth app`.

See [api.md](./api.md) for the full resolution order.

## Test runner deadlock (Zig 0.16)

Zig 0.16's server-mode test runner (`--listen=-`, `std.zig.Server` over stdio)
can deadlock the build runner on Windows: the spawned `test.exe` waits on
stdin forever while the runner prints nothing, so CI appears stuck right
after `zig version`. `zig build test` therefore runs test binaries through
plain `Step.Run` steps (exit code verdict) rather than `addRunArtifact`. See
[tests.md](./tests.md#why-tests-use-plain-steprun-instead-of-addrunartifact)
before touching the run-test wiring in `build.zig`.
