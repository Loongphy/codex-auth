# Active Plan

- Execute `plans/2026-03-20-auto-switch-interval.md`.
- Resume work from the current recorded progress in that plan file.
- Record implementation progress, CI state, GitHub review comments, and `codex review` findings in that plan file as work continues.
- Every 10 minutes, run `codex-auth switch`.
- Remove this temporary section once the task is complete, the PR is green, and no actionable review findings remain.

# Documentation First

- `docs/implement.md` is the primary context for how the project works. Read it first.
- If there is a conflict between `docs/implement.md` and the code, the code is the source of truth.
- When a conflict is found, update `docs/implement.md` to match the code and call this out in the final response.

# Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

# Validation

After modifying any `.zig` file, always run `zig build run -- list` to verify the changes work correctly.
