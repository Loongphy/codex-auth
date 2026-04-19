# Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

# Validation

After modifying any `.zig` file, always run `zig build run -- list` to verify the changes work correctly.

# Execution Isolation

- Run tests, review commands, and other side-effecting tooling from an isolated directory under `/tmp/<task-name>` with `HOME=/tmp/<task-name>`.

# Release Process

- When updating and pushing a release version, always follow [docs/release.md](./docs/release.md).

# Zig API Discovery

- Do not guess Zig APIs from memory or from examples targeting other Zig versions.
- Before using or changing a Zig API, run `zig env` and `zig version` to confirm the local toolchain and source layout.
- Use the paths reported by `zig env` as the source of truth, especially `std_dir` for the standard library and `lib_dir` for other bundled Zig libraries.
- Prefer evidence from local sources: symbol definitions, nearby tests, and existing call sites in this repository.
- If the needed behavior is not clear from `std_dir`, inspect other Zig sources and tests under the local `lib_dir` tree as needed.
