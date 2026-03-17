# Documentation First

- `docs/implement.md` is the primary context for how the project works. Read it first.
- If there is a conflict between `docs/implement.md` and the code, the code is the source of truth.
- When a conflict is found, update `docs/implement.md` to match the code and call this out in the final response.

# Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

# Validation

After modifying any `.zig` file, always run `zig build run -- list` to verify the changes work correctly.

# WSL2 Windows Testing

- This project is developed in WSL2.
- When Windows-side testing is needed, use `pwsh.exe` and copy the current source to `D:/test` before running tests there.
- Use overwrite sync behavior when copying so `D:/test` matches the current source state.
- For cleanup, always use `rm -rf /mnt/d/test/*` to delete test contents under `D:/test`.
