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
```

Test files should be grouped by product area or workflow, not by implementation detail. Use names such as `api_http_test.zig`, `registry_import_test.zig`, `tui_table_test.zig`, or `workflows_live_test.zig`.

## Build Integration

`build.zig` owns the test suite with an explicit `test_files` array. For each entry, it creates a separate `b.addTest` artifact and injects the `codex_auth` package import.

This keeps failures localized to the test file that owns them and avoids a large aggregate `tests/root.zig` importing everything manually.

A small library compile test may be included to validate the package surface with `std.testing.refAllDecls`.

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
