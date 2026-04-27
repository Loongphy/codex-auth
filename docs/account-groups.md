# Account Groups

Account groups provide separate Codex homes for separate account pools.

The managed layout is:

- `default` uses `~/.codex`, which is the normal Codex home.
- every other managed group uses a folder under `~/codex-auth/groups/`.
- `~/codex-auth/groups.json` stores mappings when a group name points at a folder with a different name.
- `~/codex-auth/projects.json` remembers the preferred group for project directories.
- archived group folders move under `~/codex-auth/archive/`.

For example, a `work` group normally uses:

```sh
~/codex-auth/groups/work
```

## Managed Group Commands

```sh
codex-auth list
codex-auth group list
codex-auth group <name> status
codex-auth group create <name> [<account>...]
codex-auth group <name> login [--device-auth]
codex-auth group <name> add <account> [<account>...]
codex-auth group <name> copy [<account>...]
codex-auth group <name> move [<account>...]
codex-auth group <name> remove <account> [<account>...]
codex-auth group <name> list [--live] [--api|--skip-api]
codex-auth group <name> import <path> [--alias <alias>]
codex-auth group <name> switch [--live] [--auto] [--api|--skip-api]
codex-auth group <name> switch <query>
codex-auth group <name> auto enable|disable
codex-auth group <name> auto --5h <percent> [--weekly <percent>]
codex-auth group <name> launch [resume [session]] [-- <codext-arg>...]
codex-auth group archive <name>
codex-auth group delete <name> --force
codex-auth group <name> path
codex-auth project show
codex-auth project set-group <name>
codex-auth project clear
codex-auth launch [resume [session]] [-- <codext-arg>...]
```

`group list <name>`, `group status <name>`, and `group path <name>` are also accepted as aliases for the preferred `group <name> ...` forms.

`list` shows the cross-group account dashboard from the default `CODEX_HOME`, separated into group sections and including a `GROUP` column for each account row. In color terminals, `default` uses gray and managed groups use their assigned display colors; active rows and group separators are bold/darker, while inactive rows use lighter tones from the same group color.

Use `group <name> list --skip-api` to print one group's accounts using local data. Use `group <name> switch` to open the interactive switcher inside one group, or `group <name> switch <query>` to switch directly. Use `group <name> status` for service and auto-switch status, and `group <name> path` for the group's `CODEX_HOME`.

## Logging In To A Group

Use group login when the account should be added directly to one pool:

```sh
codex-auth group work login
codex-auth group work login --device-auth
```

The command runs `codex login` with `CODEX_HOME` set to the `work` group folder, then imports that group's new `auth.json` into the same group registry.

Top-level login can target a group too:

```sh
codex-auth login --group work --device-auth
```

The group must already exist. Create it first with `codex-auth group create work` if you want to choose or create the backing folder.

## Creating a Group

`group create work` creates or reuses the managed Codex home for `work`.

In an interactive terminal, if there are unused folders under `~/codex-auth/groups/`, the command shows them and lets the user attach `work` to one of those folders. If no unused folder is selected, it asks for a new folder name and defaults to `work`.

In non-interactive mode, `group create work` uses `~/codex-auth/groups/work`.

## Adding Existing Accounts

Account selectors can be display numbers, aliases, email fragments, account names, or account keys.

When adding an account to a managed group, the command searches all known groups:

```sh
codex-auth group work add personal@example.com
```

If the match is in `default`, it is copied directly from `~/.codex` into the `work` Codex home.

If the match is in another non-default group, the command tells the user where it was found and asks for confirmation before copying it into the target group.

For explicit transfer commands:

```sh
codex-auth group trading copy beta@example.com
codex-auth group trading move work-only@example.com
```

`copy` leaves the source group unchanged, so a copied account can appear under both group sections in `codex-auth list`. That is expected: each group has its own `CODEX_HOME`, registry, sessions, and active account.

`move` imports the account into the target group, then removes it from the source group. It is the command to use when the account should belong to the new pool instead of the old pool.

With no account selector, `copy` and `move` open an interactive picker showing accounts from all other groups:

```sh
codex-auth group trading copy
codex-auth group trading move
```

## Launching Codext

Use `group <name> launch` instead of manually prefixing every command with `CODEX_HOME=...`:

```sh
codex-auth group work launch
codex-auth group work launch -- --model gpt-5.4
codex-auth group work launch resume
codex-auth group work launch resume 019db67d-2190-7563-a899-ce3082e491cf
```

The launched `codext` process receives `CODEX_HOME` for that group. Extra launch arguments are passed through to `codext`, so `launch resume` has the same behavior as running `codext resume` inside that group. The optional session argument can be any selector that `codext resume` normally accepts. Changing `CODEX_HOME` in another terminal does not affect a `codext` process that was already launched.

`group <name> launch` also remembers `<name>` for the current project directory. After that, plain launch uses the remembered group:

```sh
codex-auth launch
codex-auth launch -- --model gpt-5.4
codex-auth launch resume
codex-auth launch resume 019db67d-2190-7563-a899-ce3082e491cf
```

To manage the remembered project group directly:

```sh
codex-auth project show
codex-auth project set-group work
codex-auth project clear
```

If no group is remembered for the project, `launch` uses `default`, which maps to `~/.codex`.

## Per-Group Auto-Switch Settings

Each managed group has its own auto-switch and API settings in that group's `CODEX_HOME`:

```sh
codex-auth group work auto enable
codex-auth group work auto --5h 12 --weekly 8
codex-auth group work config api enable
codex-auth group work auto disable
```

The background runtime is one manager service for all enabled groups. It reads the group config, then checks each enabled group's own `CODEX_HOME` independently. Older per-group service identities are removed during enable/reconcile.

Use `group status` for a dashboard of all groups and `group <name> status` for the standard auto-switch status of one group.

## Archive And Delete

`group archive <name>` moves the managed group folder to `~/codex-auth/archive/<name>-<timestamp>` and removes the group/project mapping. It is meant as the reversible cleanup path before deleting a group permanently.

`group delete <name> --force` permanently removes the managed group folder and its mapping. The `default` group cannot be archived or deleted.

## Legacy Registry Groups

`group use <name>|none` still exists for the lower-level registry grouping inside the current `CODEX_HOME`. It stores an active group in that one registry and scopes plain `list`, `switch`, and auto-switch candidate selection inside that registry.

For separate account pools and separate Codex sessions, prefer the managed group commands above.
