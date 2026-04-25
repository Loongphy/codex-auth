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
