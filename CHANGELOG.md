# Changelog

## 0.8.0 - 2026-08-24

- Optionally join newly opened windows to the current Stage Manager group.
- Use WindowManager's Accessibility actions with stable group snapshots and a
  fail-open timeout.
- Confirm the source from the focused window instead of waiting on stale
  WindowManager group data, reducing launch latency without weakening the AX
  checks used before and after `AXAddToStage`.

## 0.7.0 - 2026-08-24

- Allow each role to override its new-window menu path.
- Document a Finder role that opens `File > New Finder Window`.

## 0.6.0 - 2026-08-24

- Cycle repeated launcher calls through an application's windows.
- Prefer an application window in the current Space on the first call.
- Track focus order across Spaces and stabilize cross-Space window focus.

## 0.1.0 - 2026-08-22

- Add semantic application roles.
- Launch or focus applications by bundle ID.
- Bind and remove personal launcher hotkeys.
