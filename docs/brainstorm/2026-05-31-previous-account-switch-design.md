# Previous Account Switch Design

## Goal

Add a `cd -` style shortcut for returning to the previous active account.

The shortcut must support both:

```shell
codex-auth -
codex-auth switch -
```

Both commands must have the same behavior.

## User-Facing Behavior

`codex-auth -` and `codex-auth switch -` switch to the previous active account. On success, output stays consistent with the existing switch command:

```text
Switched to <label>
```

If there is no previous active account, the command fails with:

```text
error: no previous account to switch to.
```

If the recorded previous account no longer exists, the command fails with:

```text
error: previous account is no longer available.
```

No hint line is needed for these errors.

`codex-auth switch - --api`, `codex-auth switch - --skip-api`, and `codex-auth switch - --live` keep the same usage-error style as query mode. Help and usage text should list `switch -` explicitly so the syntax is visible.

## State Model

Add a top-level field to `registry.json`:

```json
"previous_active_account_key": "..."
```

The in-memory registry gets a matching nullable field:

```zig
previous_active_account_key: ?[]u8
```

When loading an older registry without this field, treat it as `null`.

## Update Rules

Account activation should remain centralized in the registry layer.

When the active account changes from A to B:

```text
previous_active_account_key = A
active_account_key = B
```

This applies to successful switch paths and other existing paths that call the shared active-account setter.

If there is no current active account, setting an active account does not create a previous account.

If the target account is already active, keep the current behavior: the command succeeds and prints the standard switch success message, but the previous account is not changed.

## Previous Switch Flow

The previous-account switch should:

1. Load and sync the registry the same way query switch does.
2. Read `previous_active_account_key`.
3. Fail if it is missing.
4. Fail if it does not point to an account in the registry.
5. Reuse the normal account activation path for the target previous account.
6. Save the registry and print the normal switched-account message.

Because normal activation updates the previous field, successful previous switches naturally alternate between two accounts.

## Remove Behavior

Removing an account must not leave `previous_active_account_key` pointing to a deleted account.

Rules:

- If the removed account is the recorded previous account, clear `previous_active_account_key`.
- If the removed account is the active account and the existing remove flow automatically selects a replacement active account, keep the existing previous account if it still exists.
- Do not record the deleted active account as previous during automatic replacement.
- If neither the active nor previous account is removed, leave previous unchanged.

The automatic active-account replacement after removal is treated as cleanup, not as a user-initiated switch.

## Parsing And Help

Top-level parsing should recognize:

```shell
codex-auth -
```

as the same command as:

```shell
codex-auth switch -
```

Switch parsing should treat a lone `-` as previous-account mode, not as a normal query selector. `switch -` with API or live flags should keep the existing query-mode usage error pattern.

Help should show:

```text
codex-auth -
codex-auth switch -
```

The switch command documentation should explain that `-` returns to the previous active account.

## Testing

Add focused tests for:

- parsing `codex-auth -`;
- parsing `codex-auth switch -`;
- rejecting `switch -` combined with `--api`, `--skip-api`, or `--live`;
- loading old registry data without `previous_active_account_key`;
- writing the new registry field;
- updating previous when active changes from A to B;
- preserving previous on same-account activation;
- switching back and forth with `switch -`;
- failing when no previous account exists;
- failing when the previous account no longer exists;
- clearing previous when the previous account is removed;
- preserving previous when active is removed and a replacement active account is selected.

After changing Zig files, run:

```shell
zig build run -- list
```

Broader tests should cover the parser, registry behavior, and CLI integration paths touched by this change.
