# Test Organization

This project keeps production modules behind normal module boundaries, while test files are compiled as separate test roots from `build.zig`.

## Goals

- Keep production code free of inline `test` blocks.
- Keep test-only fixtures outside `src/`.
- Run each test file as an independent Zig test artifact.
- Preserve the exact test descriptions from `main` when refactoring behavior.
- Prefer public behavior-oriented module boundaries over test-only access shims.

## Directory Layout

```text
src/
  root.zig              # public package surface
  ...                   # production modules only

tests/
  *_test.zig            # behavior and regression tests
  support/
    fixtures.zig        # test-only builders and file helpers
    codex_daemon.zig    # scripted codex daemon double
    scripted_transport.zig  # in-memory Transport double (see below)
```

Test files should be grouped by product area or workflow, not by implementation detail. Use names such as `api_http_test.zig`, `registry_import_test.zig`, `tui_table_test.zig`, or `workflows_live_test.zig`.

## Choosing a Test Layer

Tests split by *kind*, not by "interaction vs logic". Pick the layer by what the new code changes:

- **Pure mapping and dispatch logic** — bytes → classification, key → viewport delta, rows → rendered lines — belongs in the product-area test file next to its fixtures: input classification in `tests/tui_session_test.zig`, viewport and rail behavior in `tests/cli_picker_test.zig`. Those tests share builders with the rendering tests around them; pulling them into a separate directory would only duplicate fixtures or force cross-file imports.
- **End-to-end wire tests** that need the real binary on a real terminal belong in `tests/tui_pty_test.zig` (Linux-only pseudo-terminal harness) or `tests/cli_integration_test.zig` (subprocess capture, no tty). They own their harness helpers and assert on the wire contract — mode bytes on enter/exit, reply sequences, input consumption — not on rendered frames, which the in-process tests already pin.

So a new key mapping or escape classification gets a unit test in the area file; it earns a PTY case only when the wire contract itself changes — a new DECSET, a new reply that must be consumed, or bytes that must never leak into later input. PTY coverage is gated to platforms the harness supports (`has_pty` in `tests/tui_pty_test.zig`); on other platforms the same contract stays covered at unit level.

Windows has its own counterpart in `tests/tui_conhost_test.zig`: it hosts the app inside a headless `conhost.exe` — real console handles, not pipes — then attaches to that console to inject `INPUT_RECORD`s with `WriteConsoleInputW` and read the rendered screen buffer back. It is the e2e proof of the `MOUSE_WHEELED` → scroll path. The record→key mapping itself is pinned on any host by the pure `windowsMouseScrollKey`/`windowsTuiInputMode` tests since `win.INPUT_RECORD` shapes are platform-independent.

The same file also hosts the app through real shells — `powershell.exe` (Windows PowerShell 5.1, always present) and `pwsh.exe` (PowerShell 7, when installed; override the binary location with `CODEX_AUTH_CONSOLE_PWSH_EXE`). Console semantics are identical whichever shell launched the app — the console belongs to conhost, not the shell — so the shell legs exist to cover the realistic launch chain (env inheritance through a process tree), not a second console contract. They spawn with the parent environment inherited and the test vars overlaid: shells need the full user session (`SystemDrive`, `PSModulePath`, `APPDATA`, …) that a minimal env block lacks.

Running the windows harness needs a real Windows host with a conhost that accepts `--headless` — a one-time probe skips every console test cleanly on hosts too old for it rather than failing on the descendant-poll deadline. Where supported, `zig build test` just works: the binary resolves through the same env contract as the pty harness (`CODEX_AUTH_CLI_INTEGRATION_INSTALL_PREFIX`, else `zig-out/bin` under the project root, located via `CODEX_AUTH_CLI_INTEGRATION_PROJECT_ROOT` or the compiled-in root). From WSL, `zig build test -Dtarget=x86_64-windows-gnu` executes the windows test exes through the interop layer; the recommended WSL flow is still to stage `codex-auth.exe` onto the Windows filesystem (not `\\wsl$`) and set the prefix env, since the project-root fallback then hands Windows code a Linux `/coding/...` path that only resolves by accident of the UNC working directory:

```powershell
cd <stage>; $env:CODEX_AUTH_CLI_INTEGRATION_INSTALL_PREFIX = "<stage>"; .\tui_conhost_test.exe
```

## Build Integration

`build.zig` owns the test suite with an explicit `test_files` array. For each entry, it creates a separate `b.addTest` artifact and injects the `codex_auth` package import.

This keeps failures localized to the test file that owns them and avoids a large aggregate `tests/root.zig` importing everything manually.

A small library compile test may be included to validate the package surface with `std.testing.refAllDecls`.

### Why tests use plain `Step.Run` instead of `addRunArtifact`

`b.addRunArtifact` on a test compile enables Zig's server-mode test runner:
the binary is spawned with `--listen=-` and talks `std.zig.Server` over stdio,
giving per-test timeouts, crash respawn, and result metadata. On Windows, that
protocol intermittently deadlocks: the build runner spawns the test server and
then never services it, so the child waits on stdin forever while the runner
emits no output — CI then shows only `zig version` until the job is cancelled
(upstream race, also seen on ziglang's own `x86_64-windows` CI in
ziglang/zig#25029).

Each test step is therefore a plain `std.Build.Step.Run` with
`addArtifactArg`, which runs the binary in terminal mode and treats its exit
code as the verdict. Per-test output (`N/N name...OK`) still streams to the
log. Do not "simplify" this back to `addRunArtifact`, and do not set
`run.stdio = .inherit` on an `addRunArtifact` result — the step still passes
`--listen=-` and the runner aborts with `internal test runner failure:
ReadFailed`.

## Production/Test Boundary

Production modules must not import `tests/` or `tests/support/`.

Avoid `test_api` or other test-only public namespaces in `src/`. If a rule is important enough to test directly, prefer one of these options:

1. Test it through a public behavior or workflow.
2. Extract it into a focused production module with a normal public API.
3. Make the helper public only when it is a stable, useful module boundary.

Private implementation details that are not stable behavior should not be tested directly.

## Fixtures

Fixtures belong under `tests/support/`. Import them with a relative path from tests:

```zig
const fixtures = @import("support/fixtures.zig");
```

Do not expose fixtures from `src/root.zig`.

## Mock Backend

`tests/fake_curl.zig` is the mock backend, installed as `curl` by
`zig build test-helpers`. `codex-auth` resolves `curl` from `PATH`, so putting the
mock first shadows the real one without touching any production code path.
`test-helpers` also installs `tests/fake_curl_fail.zig` as `curl-fail` (a stub
that always exits 1, for transport-failure paths) and `tests/fake_codex.zig` as
`fake-codex` (a stand-in `codex` binary for app-launch integration tests).

Without `CODEX_AUTH_FAKE_CURL_DIR` it answers the two fixed bodies the older tests
were written against. With it, the directory drives the responses:
`usage[-<account_id>].json`, `credits[-<account_id>].json`,
`accounts[-<account_id>].json`, `me.json` and `consume[-<account_id>].json` supply
bodies (a per-account consume fixture wins over the global one, so a single live
session can redeem for one account and fail for another), a sibling
`<name>.status` file supplies a non-`200` status, a sibling `<name>.exit` file makes
that one request fail like curl would (so a single account in a batch can fail
transport while the others succeed), and `after-consume-*.json` takes over once a
redeem succeeded. `CODEX_AUTH_FAKE_CURL_SCENARIO` selects a built-in consume outcome
(`ok`, `already_redeemed`, `no_credit`, `nothing_to_reset`, `unknown_code`, `http500`,
`timeout`, `resolve_failed`). `requests.log` records each consume request with its
body, and never a credential; tests assert both.

The mock replaces only the HTTP peer: the CLI binary, registry and usage parsing, the
rail renderer and the exit codes are all the real thing. It is a `test-helpers`
artifact, so it is never part of a release package: the release and preview workflows
copy `zig-out/bin/<binary_name>` alone into the uploaded artifacts.

## Transport Port

`src/api/transport.zig` is the port between the endpoint modules and the HTTP
machinery: a `Transport` vtable covering `getJson`, `bearerGetJson`, `getJsonBatch`
and `postJson`. Workflow entry points assemble `Transport.curl()`, so the shipped
binary always talks through the real curl child process. This is a production
architecture boundary, not a test-only seam.

Tests wire `tests/support/scripted_transport.zig` instead: an in-memory transport
that queues responses per verb, injects transport failures, and records every
request as structured data. Port-level tests (e.g. `api_reset_credits_test.zig`)
run endpoint logic in-process — no process spawn, no fixture files, no parsing of
curl config text.

The split between the two doubles:

- Port level owns scenario coverage: outcome matrices, per-account behavior,
  request/body assertions. `reset_credits` is the reference implementation;
  route any other endpoint through the port when you next modify it or need
  port-level coverage for it.
- Fake curl owns the curl assembly contract: argv/config construction, exit-code
  to error mapping, timeouts, output caps, plus a thin end-to-end slice through
  the real binary.

## Test Descriptions

When refactoring, test descriptions must remain compatible with `main`. This is part of the compatibility contract. A refactor is acceptable only when the set of test descriptions remains unchanged unless the behavior itself intentionally changes.

## Validation Checklist

After changing `.zig` files, run these from an isolated `/tmp/<task-name>` directory with isolated `HOME` and `CODEX_HOME`:

```sh
zig fmt $(find /path/to/repo -name '*.zig' -type f | sort)
zig build --build-file /path/to/repo/build.zig --cache-dir /tmp/<task-name>/cache test
zig build --build-file /path/to/repo/build.zig --cache-dir /tmp/<task-name>/cache run -- list
git diff --check
```

Also verify:

```sh
rg '^test "' src
rg 'test_api|src/testing|testing\.fixtures' src tests
```

The first command should return no source inline tests. The second command should return no `test_api` or production fixture exports.
