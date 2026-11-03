# Registry Schema

This document defines the on-disk format of
`<codex_home>/accounts/registry.json`, the compatibility rules that protect it,
and the migration process.

## Scope

- `app_version` is the CLI release version from `src/version.zig`.
- `schema_version` is the registry format compatibility gate stored in
  `registry.json`.
- `schema_version` is not the same thing as `app_version`.
- `list --json` has its own `schema_version`; see
  [json-api.md](./json-api.md).

`schema_version` is not a changelog and not a hash of the file shape. It
answers one question:

> May an older binary safely read and rewrite this file?

## Compatibility Model

### Backward compatibility

New binaries must be able to read old registries. Supported old layouts are
migrated on load and rewritten in the current format.

### Forward compatibility

Old binaries must not silently corrupt or degrade newer registries.

The current implementation is intentionally fail-fast:

- a registry with a newer `schema_version` is rejected with
  `UnsupportedRegistryVersion`;
- the rejected file is not rewritten.

This protects authoritative state, but it also means a bump is a hard lockout
for older binaries. A bump is therefore a compatibility decision, not a routine
way to record a new field.

### Round-trip compatibility

The current implementation does **not** preserve unknown keys. Every mutation
loads the registry into the typed model and rewrites the whole file. A binary
that accepts a file but does not know a field will drop that field on the next
write.

This is the "rewriting-proxy" hazard:

```text
older binary reads a same-version file
  -> parses known fields
  -> rewrites the whole file
  -> unknown fields are silently lost
```

Consequences:

- additive fields must either be recoverable, or require a bump;
- adding a field is not automatically safe just because it is optional;
- the data class matters as much as the field shape.

### What `schema_version` means

- It is a single monotonic integer.
- It is a compatibility gate, not a feature list.
- A bump means: "older binaries must not read or rewrite this file."
- A no-bump additive change means: "older binaries may ignore or drop this
  data; the new binary can tolerate its absence."

Do not bump merely to announce a new optional field. Do not skip a bump for a
change that old binaries can misread.

## Change Classification

| Change | Typical impact | Version action |
| --- | --- | --- |
| Remove a persisted field | old code loses data or fails | bump |
| Rename a persisted field | old code cannot find the value | bump |
| Change a field type | parse failure or silent coercion | bump |
| Change units, encoding, or timezone semantics | values look valid but mean something else | bump |
| Change the default for a missing field | behavior changes without a shape change | bump |
| Change identity keys or snapshot filenames | data cannot be matched or found | bump |
| Add a required field | old files cannot satisfy the new contract | bump + migration |
| Add an optional field | may be safe; depends on reader/writer behavior and data class | decide |
| Add an enum value | safe only if old readers map unknown values to `unknown` | usually no bump |
| Add a derived or cache field | loss is recoverable | usually no bump |
| Change CLI output, logs, help, or docs | not persisted state | no bump |

### Optional fields

"Optional" is necessary but not sufficient. An optional field still needs a
decision when an older writer drops it.

Safe no-bump cases generally have all of these properties:

- the loader treats a missing value as `null` or another safe default;
- the field does not change the meaning of existing fields;
- an older reader ignores the field rather than misreading it;
- the value is derived, cached, or otherwise recoverable;
- the recovery path is documented and tested.

A bump is required when any of these is true:

- an older reader would misinterpret the value;
- the field is authoritative and cannot be reconstructed;
- the field is required for correct operation;
- the field changes existing identity or lookup rules.

## Decision Criteria

### 1. Semantic safety

Ask whether an older binary would **misread** the new data, not merely miss it.

- ignoring an unknown field is usually safe;
- treating a seconds value as milliseconds is not;
- mapping an unknown enum to a wrong known value is not;
- accepting a renamed field as a different field is not.

### 2. Data authority

Classify the data before deciding the version action.

| Data class | Examples | Loss behavior | Version action |
| --- | --- | --- | --- |
| Authoritative identity | account key, ChatGPT account id, user id | cannot be reconstructed | bump or preserve unknown fields |
| User-authored configuration | aliases, account names, API config, refresh interval | user must re-enter it | bump or preserve unknown fields |
| Derived metadata | plan, auth mode, `access_token_expires_at`, `plan_expires_at` | recoverable from auth or usage data | no bump if missing is safe |
| Usage cache | `last_usage`, `last_usage_at`, `reset_credit`, `last_local_rollout` | refetched or re-derived | no bump if missing is safe |
| Display-only data | derived labels and timestamps | temporary degradation | no bump |

If the data is authoritative and an older writer would drop it, the options are:

1. bump `schema_version`; or
2. implement unknown-field preservation so old writers round-trip it.

Do not rely on "the field is optional" alone.

### 3. Reader and writer behavior

Check both sides:

- Does the old reader ignore unknown keys, reject them, or misinterpret them?
- Does the old writer preserve unknown keys or rewrite from a typed model?
- Does the new reader require the field, or can it degrade gracefully?
- Does the new writer preserve unknown fields for future versions?

The current answer is:

- old readers reject newer `schema_version`;
- old writers may drop unknown fields at the same version;
- new readers use safe defaults for optional fields;
- unknown-field preservation is not implemented yet.

### 4. Recovery

For a derived or cache field, answer:

- Where does the value come from?
- Can it be rebuilt without network access?
- On which command or refresh path is it rebuilt?
- What does the UI show before it is rebuilt?
- Is the loss observable and temporary, or silent and permanent?

`plan_expires_at`, for example, is rebuilt from the stored `id_token` on auth
sync and from the usage refresh path. A missing value renders as `-` until the
next refresh. That is a temporary display degradation, not credential loss.

### 5. Mixed fleet and cost

A bump is a hard lockout for older binaries. Consider:

- downgrades and parallel installs;
- package managers that keep an older binary;
- users who share or sync a Codex home;
- the cost of forcing every reader to upgrade for an optional field.

If an old binary rejecting the file would be more harmful than losing a
recoverable cache value, prefer no bump plus a documented recovery path.

## Versioning Policy

### Must bump

- Removing, renaming, or changing the type of a persisted field.
- Changing units, encoding, or timezone semantics.
- Changing the meaning of an existing field or its missing-value default.
- Changing identity keys, snapshot filenames, or lookup paths.
- Adding a required field.
- Any change an older binary would misinterpret.
- Any authoritative state that cannot be reconstructed and would be dropped by
  an older writer.

### May skip the bump

- An optional field with a safe missing-value default.
- A field that is derived, cached, or refetchable.
- A field that does not change existing semantics.
- An enum value that older readers safely map to `unknown`.
- Output, logging, help text, or documentation changes.

A no-bump decision must document:

- the source of truth;
- the recovery path;
- the behavior while the field is absent;
- the tests that cover an older registry without the field.

### Requires more than a bump

Some changes need a mechanism, not only a version number:

- An authoritative field that older writers would drop:
  implement unknown-field preservation, or bump.
- A mixed-version fleet that must keep working:
  add a capability or `min_reader_version` marker, or keep additive fields
  recoverable.
- A large derived payload:
  put it in a separate cache section or file with its own version and an
  explicit "safe to discard" contract.

### Never do without a bump

- Reuse a field name for different semantics.
- Change a timestamp from seconds to milliseconds.
- Change an identity key while keeping the old key.
- Treat missing data as a different plan, account, or entitlement.
- Silently reinterpret an existing field.

## Current Schema

The current persisted format is `schema_version = 4`.

The schema `4` account layout is the same as schema `3`, with these
differences:

- live refresh interval stored as top-level `interval_seconds`;
- older `live.interval_seconds` and removed `auto_switch` blocks are omitted on
  rewrite;
- top-level `previous_active_account_key` supports `codex-auth -` and
  `codex-auth switch -`;
- persisted plans use final product semantics rather than backend identifiers;
- legacy `team` becomes `business`;
- legacy `business` becomes `enterprise`;
- the same conversion applies to per-account `last_usage.plan_type`.

Optional derived fields have been added to schema `4` without a bump, including
`access_token_expires_at`, `last_usage.reset_credit`, and `plan_expires_at`.
They are missing-as-null, recoverable from auth or usage data, and do not change
the meaning of existing fields. They are cache additions within the schema `4`
compatibility boundary, not a new registry format.

## Migration

This section covers the migration contract for older registries.

### Supported paths

- `schema_version = 3 -> schema_version = 4` is the guaranteed automatic
  migration.
- The legacy `version = 2` loader is retained and rewrites directly to schema
  `4`; it is not the compatibility boundary for current development.
- Current-layout files that still use the old top-level `version = 3` key, or
  still carry the old global `last_attributed_rollout` shape, are normalized to
  schema `4`.
- Users are expected to upgrade directly to the latest binary; intermediate
  releases are not required.
- A `schema_version` newer than the current binary is rejected with
  `UnsupportedRegistryVersion` and is not rewritten.

### Migration rules

- Load the old layout, migrate in memory, then rewrite `registry.json` in the
  current format.
- Preserve account records, active account selection, previous active account
  selection, and account-snapshot usability.
- Create the usual `registry.json.bak.*` backup before replacing the file.
- Migration may reset derived or cache fields that cannot be reconstructed from
  the old layout; it must not silently drop authoritative identity or user
  configuration.
- If the file cannot be migrated safely, fail without writing.
- Do not write a file whose version the binary does not understand.

### Failure behavior

- A newer `schema_version` fails with `UnsupportedRegistryVersion` before any
  write.
- A malformed or unsupported older layout must not be converted into a
  partially valid registry.
- The original file remains available, and the normal backup and `clean`
  recovery paths still apply.

## Adding or Changing a Persisted Field

Use this checklist before changing `registry.json`:

1. Classify the data as authoritative, user-authored, derived, or cache.
2. Check whether an older reader would ignore or misread the new value.
3. Check whether an older writer would drop it on rewrite.
4. Decide bump or no bump using the criteria above.
5. For a no-bump change:
   - treat missing data as `null` or a safe default;
   - document the source of truth and recovery path;
   - test loading an older registry without the field;
   - test the display or behavior while the field is absent.
6. For a bump:
   - add the migration step and backup behavior;
   - preserve authoritative records;
   - test old layouts, current layouts, and a too-new layout;
   - update the current schema version and history.
7. Update the JSON contract when the field is exposed by `list --json`.
8. Run the normal build, test, and CLI validation steps.

Before bumping, confirm the decision with the maintainer. Do not bump silently,
and do not leave the document and the implementation on different policies.

## JSON Output Schema

The `list --json` document has its own `schema_version = 1`, documented in
[json-api.md](./json-api.md). It is separate from the registry version.

Additive optional JSON fields do not require a schema bump: clients are required
to ignore unknown fields, and the new fields are optional. Registry compatibility
and JSON compatibility are independent contracts.

## Related Documents

- JSON output contract: [json-api.md](./json-api.md)
- Implementation index: [implement.md](./implement.md)
- Dynamic column layout: [dynamic-columns.md](./dynamic-columns.md)
