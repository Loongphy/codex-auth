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
- [ ] Commit the planning setup and open a Draft PR.

### Phase 2: CLI and Flow Changes

- [ ] Extend `RemoveOptions` to carry an optional positional query.
- [ ] Update `parseArgs`, `freeCommand`, and help output for `remove [<query>]`.
- [ ] Update `handleRemove` to support query-based deletion and summary output.
- [ ] Add/remove helpers needed for confirmation prompts and remove summaries.
- [ ] Change remove selection so non-TTY stdin goes straight to numbered selection.

### Phase 3: Tests and Docs

- [ ] Add/adjust unit tests for parsing, matching, summary rendering, and selector mode choice.
- [ ] Add/adjust e2e coverage for query deletion and non-TTY remove behavior.
- [ ] Update `docs/implement.md` for the new remove behavior.
- [ ] Run required validation, including `zig build run -- list`.

### Phase 4: PR Follow-up

- [ ] Push implementation commits.
- [ ] Review PR CI and review comments.
- [ ] Log each comment and disposition in this file.
- [ ] Fix accepted comments, commit, push, and resolve conversations.
- [ ] Repeat until CI is green and there are no outstanding actionable comments.
- [ ] Run `/review` loop, log outcomes here, address valid findings, and repeat until clean.
- [ ] Remove the temporary `AGENTS.md` plan reference before the task is fully complete.

## Progress Log

- 2026-03-20: Worktree created at `/tmp/codex-auth--fix-remove-command` on branch `fix/remove-command`.
- 2026-03-20: Created `plans/2026-03-20-remove-command.md` and added a temporary active-plan note to `AGENTS.md`.
- 2026-03-20: Requirements confirmed:
  - support `codex-auth remove <query>`
  - no `--email` flag
  - query matches alias or email
  - multi-match query path asks for explicit delete confirmation
- 2026-03-20: Implementation not started yet.

## PR / Review Log

- Pending.
