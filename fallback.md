# Fallbacks

## Live refresh falls back to stored registry data

- Reason: `list --live` and `switch --live` still need a usable selector when a best-effort foreground refresh pass cannot produce an updated display; `switch --live` then reloads the stored view immediately after a successful selection and lets the next scheduled refresh refill any API-backed overlays.
- Protected callers or data: interactive live-mode CLI users and the persisted registry snapshots under the active Codex home.
- Removal conditions: remove this fallback only if live mode is intentionally changed to fail closed.

## Windows CLI falls back to ASCII-only and ANSI-free status output

- Reason: Windows PowerShell and ConHost sessions can still decode console bytes with a legacy code page such as CP936, which garbles UTF-8 arrows and checkmarks into text like `鈫?`, and some sessions also leak ANSI reset sequences as visible text such as `0m`; Windows builds therefore use ASCII-only navigation hints and import-status markers and disable ANSI colors until console writes are Unicode-safe end-to-end.
- Protected callers or data: Windows interactive selector users and Windows `import` CLI users reading status output in PowerShell 7, Windows Terminal, or classic console hosts.
- Removal conditions: remove this fallback only after Windows CLI output is emitted through a Unicode-safe path and verified in localized PowerShell/console environments.
