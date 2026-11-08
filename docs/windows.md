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
- In-flight steps are announced with a `- ` prefix and a completed step with an
  `OK ` prefix instead of a check mark.

### Reset credits rail and `reset` output

The `list --live` reset credits rail is borderless on every platform; Windows
only changes the shared glyph set: the `·` field separator becomes `, `, a
success status marker becomes `OK `, and a failure line carries no marker at
all because its sentence already says what happened. `codex-auth reset` prints
the same separator difference outside the TUI. The exact rendering of both is
pinned by tests (`tests/cli_picker_test.zig`, `tests/cli_behavior_test.zig`).

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

## Test runner deadlock

Zig's server-mode test runner (`--listen=-`, `std.zig.Server` over stdio)
can deadlock the build runner on Windows: the spawned `test.exe` waits on
stdin forever while the runner prints nothing, so CI appears stuck right
after `zig version`. `zig build test` therefore runs test binaries through
plain `Step.Run` steps (exit code verdict) rather than `addRunArtifact`. See
[tests.md](./tests.md#why-tests-use-plain-steprun-instead-of-addrunartifact)
before touching the run-test wiring in `build.zig`.
