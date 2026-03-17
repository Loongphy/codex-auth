# Documentation First

- `docs/implement.md` is the primary context for how the project works. Read it first.
- If there is a conflict between `docs/implement.md` and the code, the code is the source of truth.
- When a conflict is found, update `docs/implement.md` to match the code and call this out in the final response.

# Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

# Validation

After modifying any `.zig` file, always run `zig build run -- list` to verify the changes work correctly.
