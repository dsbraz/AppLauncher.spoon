# AppLauncher

Personal Hammerspoon Spoon that launches or focuses applications by semantic
role. Roles keep the keyboard map stable when the application used for a job
changes.

For a running application, the first shortcut press prefers its most recently
focused window in the current Space. If the application is already frontmost,
subsequent presses cycle through its actual windows in focus order, including
windows in other Spaces. Cross-Space focus is reasserted until the transition
settles. Applications that are not running are launched by bundle ID.

The cycle covers standard, non-minimized windows. Application tabs are not
separate windows and therefore are not part of it.

## Configuration

```lua
local hyper = { "cmd", "ctrl", "alt" }

hs.loadSpoon("AppLauncher")

spoon.AppLauncher.apps = {
  browser = "com.google.Chrome",
  editor = "dev.zed.Zed",
  files = "com.apple.finder",
  git = "com.gitbutler.app",
  ide = "com.jetbrains.rider",
  terminal = "com.mitchellh.ghostty",
}

spoon.AppLauncher.newWindowMenuItems = {
  files = { "File", "New Finder Window" },
}
spoon.AppLauncher.joinNewWindowsToCurrentStage = true

spoon.AppLauncher:bindHotkeys({
  browser = { hyper, "b" },
  editor = { hyper, "e" },
  git = { hyper, "g" },
  ide = { hyper, "i" },
  terminal = { hyper, "t" },
})

spoon.AppLauncher:bindNewWindow({
  browser = { hyper, "space" },
  files = { hyper, "escape" },
  terminal = { hyper, "return" },
})
```

`bindNewWindow` takes the same role-to-hotkey shape as `bindHotkeys`, and binds
plain hotkeys: one key, one window.

A prefix mode was tried first — one key arming a mode, the role letter of the
focus shortcut choosing the application — and it had a failure mode with no way
back. Entering the mode disables the prefix key by design, and `hs.hotkey` only
lets the last-enabled binding for a combination fire. The first time a role key
reached the global binding instead of the mode's own, the mode never exited:
the shortcut behaved as a plain focus, and the prefix stayed dead until the
next reload. Plain hotkeys have no state to get stuck in.

A new window is the application's own menu item, picked through Accessibility,
so the window joins the running instance instead of starting a second copy of
the application. The default is `File > New Window`; roles that name it
differently can override the path through `newWindowMenuItems`, as Finder does
with `File > New Finder Window`.
When the application is not running yet, the role simply launches — the menu
item lives in the application's own menu bar, so there has to be a process to
read it from.

This suits roles that want another window, such as browsers, file managers, and
terminals. An application reaching the menu step without its configured item
is a misconfigured role, and says so rather than quietly focusing.

The application is deliberately **not** activated first. Activating one that
has windows on another Space sends macOS to that Space, and the new window is
then born there instead of where the shortcut was pressed. Accessibility does
not need the application frontmost to pick a menu item, so the window appears
on the current Space. Focus is then handed to that one window once it exists --
never to the application -- and a window that landed on another Space anyway is
left alone rather than dragged into view.

When `joinNewWindowsToCurrentStage` is enabled and Stage Manager is active, the
Spoon remembers the current stage before opening the window. It then invokes
WindowManager's private `AXAddToStage` Accessibility action until the windows
from the previous stage and the new window belong to the same group. Group
snapshots must agree twice before the Spoon acts. The original stage is anchored
by checking the same focused window twice, independently of WindowManager's
occasionally stale group list. If WindowManager returns unstable or unavailable
data, the new window still opens with the normal behavior. The option defaults
to `false` because the action is undocumented and may change between macOS
releases.

## Public API

- `launch(role)` launches or focuses the configured application.
- `launchNewWindow(role)` opens another window of the configured application,
  or launches it when it is not running.
- `bindHotkeys(mapping)` replaces the current bindings.
- `bindNewWindow(mapping)` replaces the current new-window bindings.
- `stop()` removes all bindings created by the Spoon.
- `status()` reports configured applications and bound roles.

## Requirements

- Hammerspoon 1.1.1 or newer
- Accessibility permission for Hammerspoon. Stage Manager grouping additionally
  depends on the private Accessibility tree of `com.apple.WindowManager`.
