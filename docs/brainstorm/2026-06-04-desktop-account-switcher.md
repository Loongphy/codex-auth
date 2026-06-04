# Desktop Account Switcher

## Goal

Add a small desktop widget for `codex-auth` that lets users switch the active Codex account from the operating system's always-available desktop area:

- Windows: notification area / system tray near the clock.
- macOS: menu bar status item.
- Linux: desktop panel tray/status notifier when the current desktop environment supports it.

The intended interaction is:

1. The user starts a lightweight background process, for example `codex-auth desktop`.
2. A `codex-auth` icon appears in the platform's tray, menu bar, or panel.
3. Clicking the icon opens an account menu.
4. Selecting an account switches the active `auth.json` immediately.

This feature should be a desktop convenience layer over the existing registry and switch workflow, not a separate account store.

## Current Project Fit

The project is a good fit for this feature because the account-switching model is already mostly platform-independent:

- Account snapshots are stored under the resolved Codex home.
- `registry.activateAccountByKey` already centralizes activation, backups, `auth.json` replacement, `active_account_key`, `previous_active_account_key`, and `last_used_at` updates.
- `codex-auth switch <query>` already has a noninteractive switch flow, but it resolves display numbers, aliases, email fragments, and account-name fragments rather than a stable internal account key.
- Display rows already group accounts by email and can mark the active account.
- The npm package already ships platform-specific native binaries through optional dependencies.
- The `app` command already contains platform-specific behavior, so the codebase has precedent for isolating desktop integration by operating system.

The desktop switcher should reuse the registry layer directly instead of shelling out to `codex-auth switch <query>`. Query switching can be ambiguous, and display numbers can change when accounts are added, removed, or regrouped.

## Product Shape

### Command

Recommended command:

```shell
codex-auth desktop
```

Possible aliases:

```shell
codex-auth tray
codex-auth menubar
```

`desktop` is the clearest cross-platform name. `tray` is familiar on Windows and Linux but less natural on macOS.

Suggested options:

```shell
codex-auth desktop
codex-auth desktop --startup install
codex-auth desktop --startup remove
codex-auth desktop --status
codex-auth desktop --quit
```

Initial MVP can ship only:

```shell
codex-auth desktop
```

Startup management, status, and remote quit can be follow-ups.

### Menu

The menu should be rebuilt from the registry each time it opens.

Suggested layout:

```text
codex-auth
---------
* personal@example.com
  Work Team
  API key sk-a1b2c***d3e4
---------
Previous account
Open account list
Quit
```

Rules:

- The active account is marked.
- Alias labels take precedence.
- Account names should be shown when available.
- Email grouping should stay consistent with the existing CLI display model.
- Disabled rows may be used for group headers.
- `Previous account` is disabled when no previous account is available.
- `Open account list` can launch `codex-auth list` in a terminal as a later enhancement. It is not required for MVP.
- All user-facing GUI text must be English.

### Switch Feedback

After a successful switch, show a short native notification when the platform supports it:

```text
Switched to <label>
```

For failures:

```text
Switch failed: <reason>
```

Avoid exposing raw account keys in menu labels, notifications, or logs.

### Codex Client Caveat

The desktop switcher changes the active auth file. The same caveat from the README still applies: Codex CLI and Codex App users may need to restart the client or session for the new account to take effect. The desktop widget should not promise seamless switching for clients that do not reload auth state.

## Architecture

Use a shared core plus thin platform adapters.

```text
src/workflows/desktop.zig
  shared command workflow

src/desktop/menu_model.zig
  shared account menu entries
  active/previous state
  stable account-key command IDs

src/desktop/switch_action.zig
  load registry
  sync active auth
  activate account by account_key
  save registry
  return display label

src/desktop/platform/windows.zig
  Windows notification-area adapter

src/desktop/platform/macos.zig
  macOS menu bar adapter

src/desktop/platform/linux.zig
  Linux status notifier / app indicator adapter
```

The platform adapters should do only platform work:

- create and destroy the icon,
- open menus,
- map menu item IDs to account keys,
- show notifications,
- handle quit and lifecycle events.

Account loading, label formatting, previous-account behavior, and switching should stay in shared code.

## Platform Adapters

### Windows

Use a native Win32 notification-area implementation.

Expected Windows concepts to validate against the local Zig version before implementation:

- hidden message-only or hidden top-level window,
- `Shell_NotifyIconW`,
- `HMENU` / popup menu APIs,
- stable application-defined tray callback message,
- clean icon removal on normal exit and message-loop shutdown.

If the build needs a GUI subsystem for a no-console process, add a separate executable:

```text
codex-auth-desktop.exe
```

Keep `codex-auth.exe` as the console CLI. The CLI command can spawn the desktop helper and exit.

### macOS

Use a native menu bar status item.

Expected macOS concepts to validate before implementation:

- `NSApplication`,
- `NSStatusBar` / `NSStatusItem`,
- `NSMenu` and `NSMenuItem`,
- app activation policy suitable for menu-bar-only apps,
- native user notification support.

The implementation may require Objective-C runtime calls or a small platform helper. If Zig interop becomes too complex, a small native helper can still use the shared account-switching contract by invoking an internal command or linking shared code.

### Linux

Linux needs more caution because there is no single universal tray.

Preferred target:

- StatusNotifierItem / AppIndicator over D-Bus.

Desktop support varies:

- KDE Plasma generally supports StatusNotifierItem.
- GNOME often needs an extension for tray icons.
- Some Wayland environments intentionally avoid legacy tray behavior.
- Minimal window managers may not provide a tray host.

Linux should degrade cleanly:

```text
error: no supported desktop status notifier was found.
```

Avoid adding heavy GTK/Electron dependencies for MVP. If a library is needed, make the dependency explicit and limited to Linux platform packages.

## Account Switching Path

Add a shared internal account-key switch helper for the desktop workflow:

1. Resolve `CODEX_HOME`.
2. Load `registry.json`.
3. Sync current `auth.json` into the registry when possible.
4. Find the selected account by `account_key`.
5. Call `registry.activateAccountByKey`.
6. Save the registry.
7. Return the same display label used by CLI switch success output.

This is the same core behavior as successful CLI switching, but driven by a stable account key chosen from the desktop menu.

Do not expose `switch --account-key` publicly unless there is a clear CLI use case. If it is exposed, document that `account_key` is an internal selector and avoid printing it by default.

## Implementation Phases

### Phase 1: Shared Non-GUI Foundation

Prepare reusable account-menu and activation code without platform GUI code.

Tasks:

- Add `desktop` command parsing and help, initially returning a platform support error if no adapter exists.
- Add a helper that loads switchable accounts from the registry and returns stable menu entries.
- Reuse existing display-label behavior where possible.
- Add an activation helper that switches by `account_key` and returns the display label.
- Add tests for menu data and account-key activation.

This phase can be validated on every platform.

### Phase 2: Windows MVP

Windows is the best first adapter because the original request was Windows-oriented and the project already has Windows-specific App code.

Tasks:

- Add a Windows notification-area icon.
- Build the account menu on demand.
- Switch selected accounts in-process.
- Support `Previous account`.
- Support `Quit`.
- Remove the icon cleanly on exit.

MVP does not need startup install, custom icons, API refresh, usage display, or Codex App controls.

### Phase 3: macOS Adapter

Add the menu bar implementation after the shared menu model is stable.

Tasks:

- Add `NSStatusItem` menu bar process.
- Reuse the same shared menu entries.
- Reuse the same switch action helper.
- Add native notifications where available.
- Validate packaging in the macOS optional dependency packages.

### Phase 4: Linux Adapter

Add Linux after deciding how much dependency surface is acceptable.

Tasks:

- Implement StatusNotifierItem/AppIndicator support.
- Detect missing tray/status-notifier hosts.
- Return a clear platform support error when unsupported.
- Validate behavior on at least KDE Plasma and GNOME with tray support enabled.

### Phase 5: Desktop Polish

Improve day-to-day usability across adapters.

Tasks:

- Add platform-appropriate icons.
- Add a single-instance guard.
- Add `--startup install|remove`.
- Add `--status` and `--quit`.
- Add a refresh menu item.
- Optionally show last-known usage percentages as menu suffixes.
- Optionally add a menu item to launch `codex-auth app`.

## Build And Packaging Considerations

The npm package currently dispatches to platform-specific native binaries through optional dependencies:

- `@loongphy/codex-auth-win32-x64`
- `@loongphy/codex-auth-win32-arm64`
- `@loongphy/codex-auth-darwin-x64`
- `@loongphy/codex-auth-darwin-arm64`
- `@loongphy/codex-auth-linux-x64`
- `@loongphy/codex-auth-linux-arm64`

The desktop feature can ship inside those platform packages.

Recommended packaging rules:

- Keep the main `codex-auth` binary as a console CLI.
- Add separate desktop helper binaries only where a GUI subsystem or platform lifecycle requires it.
- Keep platform assets scoped to the matching platform package.
- Avoid introducing cross-platform GUI frameworks unless native adapters become too costly to maintain.

Possible helper names:

```text
codex-auth-desktop.exe
codex-auth-desktop
```

The CLI command can spawn the helper and exit:

```shell
codex-auth desktop
```

## Risks And Constraints

- The account-switching core is portable; the tray/menu-bar/panel UI is not.
- Platform adapters should stay isolated from registry and CLI logic.
- Switching `auth.json` while another process reads it should remain as atomic as the existing `replaceFilePreservingPermissions` behavior allows.
- Query-based switching is not stable enough for desktop menu actions; use `account_key` internally.
- API refresh should not run automatically from the MVP. Silent background token calls would change the current risk profile documented in the README.
- Multiple desktop processes could confuse users. Add a single-instance guard before startup install support.
- Some Codex clients may not observe the switched account until restart.
- Linux support will vary by desktop environment.
- CLI-facing output for this feature must stay English, ASCII, and readable without ANSI support.

## Testing Plan

After modifying Zig files, always run:

```shell
zig build run -- list
```

Before using or changing Zig platform APIs, run:

```shell
zig env
zig version
```

Use the local `std_dir` and `lib_dir` from `zig env` as the source of truth for API names and platform bindings.

Focused tests:

- Parse `codex-auth desktop`.
- Reject unsupported desktop flags.
- Return a clear unsupported-platform or unsupported-desktop error.
- Build account menu entries from registry records.
- Mark active and previous account availability correctly.
- Switch by account key and update `active_account_key`, `previous_active_account_key`, backups, and `last_used_at`.
- Do not alter previous account when selecting the already-active account.
- Handle missing selected account key with a user-friendly error.

Manual validation:

- Icon appears in the expected OS location.
- Menu opens reliably.
- Account selection switches `auth.json`.
- Active marker updates after switching.
- `Previous account` alternates between accounts.
- Quit removes the icon.
- A second instance does not create a duplicate icon once single-instance support exists.

Platform validation:

- Windows: notification area works from PowerShell, Windows Terminal, and direct executable launch.
- macOS: menu bar item works without showing a dock icon unless intentionally configured otherwise.
- Linux: status notifier works on supported desktops and fails clearly on unsupported ones.

## Recommended MVP Scope

Build the feature as a cross-platform architecture with a Windows-first adapter:

```shell
codex-auth desktop
```

MVP includes:

- shared menu model,
- shared account-key switch action,
- Windows native notification-area adapter,
- account menu,
- active marker,
- previous-account entry,
- success/failure notification,
- quit action.

Defer:

- macOS adapter,
- Linux adapter,
- startup install,
- API refresh,
- usage percentages,
- Codex App launch integration,
- custom settings UI.

This keeps the first implementation small while avoiding a Windows-only design that would need to be reworked later.
