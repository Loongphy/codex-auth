# 2026-03-20 Remove Command Improvements

## Objective

Fix the `remove` command workflow so it is easier to use in query-based and piped flows while keeping all CLI output in English.

## Scope

1. After `handleRemove` completes successfully, print `Removed N account(s): ...`.
2. Support `codex-auth remove <query>` for alias/email fragment matching.
3. If a query matches multiple accounts, show a confirmation prompt listing the matched emails and only delete on `y`/`Y`.
4. In pipe mode, when `stdin` is not a TTY, skip the interactive `/dev/tty` UI and use the numbered remove selector directly.
5. Update documentation and tests for the new behavior.
6. Record PR review comments and CI/review follow-up decisions in this file until the PR is clean.

## Decisions

- Non-interactive query mode is positional only: no `--email` flag will be added.
- Positional query matching is case-insensitive and matches alias or email fragments, like `switch`.
- Single-match query deletion proceeds immediately.
- Multi-match query deletion requires a confirmation prompt before deleting.
- Interactive selector mode keeps the existing behavior except for the non-TTY fallback.

## Implementation Plan

### Phase 1: Planning Setup

- [x] Create this plan file and keep it updated with progress.
- [x] Temporarily update `AGENTS.md` so the active task explicitly follows this plan file.
- [x] Commit the planning setup and open a Draft PR.

### Phase 2: CLI and Flow Changes

- [x] Extend `RemoveOptions` to carry an optional positional query.
- [x] Update `parseArgs`, `freeCommand`, and help output for `remove [<query>]`.
- [x] Update `handleRemove` to support query-based deletion and summary output.
- [x] Add/remove helpers needed for confirmation prompts and remove summaries.
- [x] Change remove selection so non-TTY stdin goes straight to numbered selection.

### Phase 3: Tests and Docs

- [x] Add/adjust unit tests for parsing, matching, summary rendering, and selector mode choice.
- [x] Add/adjust e2e coverage for query deletion and non-TTY remove behavior.
- [x] Update `docs/implement.md` for the new remove behavior.
- [x] Run required validation, including `zig build run -- list`.

### Phase 4: PR Follow-up

- [x] Push implementation commits.
- [x] Review PR CI and review comments.
- [x] Log each comment and disposition in this file.
- [x] Fix accepted comments, commit, push, and resolve conversations.
- [x] Repeat until CI is green and there are no outstanding actionable comments.
- [x] Run `/review` loop, log outcomes here, address valid findings, and repeat until clean.
- [x] Remove the temporary `AGENTS.md` plan reference before the task is fully complete.

## Progress Log

- 2026-03-20: Worktree created at `/tmp/codex-auth--fix-remove-command` on branch `fix/remove-command`.
- 2026-03-20: Created `plans/2026-03-20-remove-command.md` and added a temporary active-plan note to `AGENTS.md`.
- 2026-03-20: Requirements confirmed:
  - support `codex-auth remove <query>`
  - no `--email` flag
  - query matches alias or email
  - multi-match query path asks for explicit delete confirmation
- 2026-03-20: Planning setup committed as `cc8688e` (`docs: add remove command execution plan`).
- 2026-03-20: Draft PR created: `#23 fix: improve remove command query and pipe flows`.
- 2026-03-20: Implemented:
  - positional query support for `remove`
  - multi-match confirmation prompt
  - remove summary output
  - non-TTY fallback to numbered remove selection
  - unit/e2e/doc updates
- 2026-03-20: Validation completed:
  - `env ZIG_GLOBAL_CACHE_DIR=.zig-cache/test-global ZIG_LOCAL_CACHE_DIR=.zig-cache/test-local zig test src/main.zig -lc`
  - `zig build run -- list`
- 2026-03-20: Implementation committed as `9e833b2` (`fix: improve remove command query flow`) and pushed to PR #23.
- 2026-03-20: CI follow-up:
  - `Build Preview Packages (win32-x64)` failed because `selectAccountsToRemove` compiled the `/dev/tty` branch on Windows after a runtime-only selector change.
  - Fixed by restoring a compile-time Windows branch and keeping the non-TTY fallback only for non-Windows builds.
  - Re-validated with:
    - `env ZIG_GLOBAL_CACHE_DIR=.zig-cache/test-global ZIG_LOCAL_CACHE_DIR=.zig-cache/test-local zig test src/main.zig -lc`
    - `zig build run -- list`
    - `env ZIG_GLOBAL_CACHE_DIR=.zig-cache/win-global ZIG_LOCAL_CACHE_DIR=.zig-cache/win-local zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe`
- 2026-03-20: Removed the temporary active-plan note from `AGENTS.md` in `1fc35db` (`chore: clear active remove plan note`) and pushed it to PR #23.
- 2026-03-20: Final PR check confirmed:
  - no pull request review comments
  - no review submissions
  - all GitHub Actions checks green
  - `Macroscope - Correctness Check` concluded as `skipped` with no actionable feedback

## PR / Review Log

- PR #23 created as Draft.
- Initial PR check:
  - review comments: none
  - review submissions: none
  - CI state: pending for all current checks
- CI issue recorded:
  - check: `Build Preview Packages (win32-x64)`
  - assessment: valid
  - action: fixed locally and prepared follow-up commit
- Follow-up review loop:
  - posted issue comment: `/review PR`
  - review comments generated after request: none during the observed polling window
  - review submissions generated after request: none during the observed polling window
- Current external status:
  - branch `fix/remove-command` is pushed and up to date with `origin/fix/remove-command`
  - GitHub Actions checks are green after the Windows fix and AGENTS cleanup commit
  - `Macroscope - Correctness Check` completed as `skipped`
  - PR review comments: none
  - PR review submissions: none
