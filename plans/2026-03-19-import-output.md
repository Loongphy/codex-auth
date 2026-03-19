---
name: import-output
description: Improve codex-auth import progress reporting, duplicate handling visibility, and stderr/stdout consistency
---

# Plan

Improve `codex-auth import` so import success is no longer silent, duplicate imports are clearly reported as updates, skipped files stay visible with friendly reasons, and stdout/stderr handling remains consistent with the rest of the CLI.

## Requirements
- Create and work on branch `feat/import-output`.
- Keep the repo-wide warning/error channel policy unchanged unless a concrete mismatch is found during implementation.
- Make directory import print:
  - `Scanning <path>...`
  - one per-file result line
  - `Import Summary: <imported> imported, <updated> updated, <skipped> skipped (total <N> files)`
- Make single-file import print:
  - `  ✓ imported  <label>` for a new account
  - `  ✓ updated   <label>` for an existing account
  - `  ✗ skipped   <label>: <reason>` for a failed import
- For single-file failure, also print:
  - `Import Summary: 0 imported, 1 skipped`
- Keep skipped lines and warnings on `stderr`.
- Keep scanning lines, success/update lines, and summaries on `stdout`.
- Map JSON parse failures to `MalformedJson`.

## Scope
- In: import/purge reporting changes, import result classification, stdout/stderr audit, docs updates, and tests.
- Out: non-import CLI redesign, background daemon changes, or unrelated warning/error formatting changes.

## Files and entry points
- `src/main.zig` for top-level import handling and rendering hooks
- `src/registry.zig` for import result classification and purge reporting
- `src/cli.zig` and `src/io_util.zig` for shared import output formatting/writer helpers
- `src/tests/e2e_cli_test.zig` plus existing registry/purge tests for behavior coverage
- `README.md` and `docs/implement.md` for user-facing and implementation docs

## Data model / API changes
- Replace the current minimal `ImportSummary` reporting with a richer internal report that can represent:
  - per-file display label
  - outcome: `imported`, `updated`, `skipped`
  - optional skip reason
  - totals: `imported`, `updated`, `skipped`, `total_files`
- Preserve command exit-code behavior:
  - partial batch skips still succeed if the command completes
  - fatal command-level failures still return non-zero

## Action items
- [x] Add this plan file and keep implementation aligned with it.
- [x] Add an execution-lock section to `AGENTS.md` that points at this plan until all checklist items are complete.
- [x] Refactor import internals so registry import paths return structured per-file events instead of directly logging skip warnings.
- [x] Add import output rendering that matches the agreed examples for:
  - directory import
  - repeated single-file import
  - single-file failure
- [x] Keep skipped lines on `stderr` and success/progress/summary lines on `stdout`, flushing after each line.
- [x] Add a reason-label mapper so JSON syntax errors display as `MalformedJson` while semantic validation errors keep their explicit names.
- [x] Apply the same reporting model to `import --purge`, including the final active `auth.json` sync when it produces an import/update event.
- [x] Audit the remaining repo warning/error emitters and leave them unchanged unless a real stdout/stderr mismatch is found.
- [x] Update `README.md` and `docs/implement.md` to document the new import behavior and stream split.
- [x] Add/adjust tests for import result classification, CLI output shape, and stderr/stdout separation.
- [x] Remove or update the `AGENTS.md` execution lock once every plan item is complete and validated.

## Testing and validation
- `zig test src/main.zig -lc`
- `zig build`
- `zig build run -- list`
- Add or update tests for:
  - first import -> `imported`
  - repeated import -> `updated`
  - malformed JSON -> `MalformedJson`
  - missing email / missing record key -> `skipped`
  - directory import mixed output
  - single-file success/update output
  - single-file failure output
  - purge output counting/reporting

## Risks and edge cases
- Mixed stdout/stderr output must be flushed carefully so interactive terminal order stays readable.
- Purge currently deduplicates by newest snapshot before import; skipped reporting must still reconcile with totals.
- Single-file label formatting must stay stable and not expose full absolute paths in the result line.
- The existing warning/error audit should not accidentally rewrite unrelated command output semantics.

## Assumptions
- Use filename-based labels with a trailing `.json` removed for import result lines.
- Keep the user-requested `✓` and `✗` markers without adding ANSI color for this feature.
- The execution lock in `AGENTS.md` is temporary and should be removed or replaced after this plan is completed.
