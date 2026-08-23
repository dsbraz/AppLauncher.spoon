# AppLauncher

Personal Hammerspoon Spoon that launches or focuses applications by semantic
role. Roles keep the keyboard map stable when the application used for a job
changes.

## Configuration

```lua
local hyper = { "cmd", "ctrl", "alt", "shift" }

hs.loadSpoon("AppLauncher")

spoon.AppLauncher.apps = {
  browser = "com.google.Chrome",
  editor = "dev.zed.Zed",
  git = "com.gitbutler.app",
  ide = "com.jetbrains.rider",
  terminal = "com.mitchellh.ghostty",
}

spoon.AppLauncher:bindHotkeys({
  browser = { hyper, "b" },
  editor = { hyper, "e" },
  git = { hyper, "g" },
  ide = { hyper, "i" },
  terminal = { hyper, "t" },
})

spoon.AppLauncher:bindNewWindow({
  browser = { hyper, "space" },
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

A new window is the application's own `File > New Window` menu item, picked
through Accessibility, so the window joins the running instance instead of
starting a second copy of the application. Applications that name that item
differently are covered by pointing `newWindowMenuItem` at the right path.
When the application is not running yet, the role simply launches — the menu
item lives in the application's own menu bar, so there has to be a process to
read it from.

This suits the roles that want a second window: browsers and terminals, which
all publish that item. Which application fills each role is the part that
varies, and `newWindowMenuItem` covers one naming a different path. An
application reaching the menu step without the item is a misconfigured role,
and says so rather than quietly focusing.

The application is deliberately **not** activated first. Activating one that
has windows on another Space sends macOS to that Space, and the new window is
then born there instead of where the shortcut was pressed. Accessibility does
not need the application frontmost to pick a menu item, so the window appears
on the current Space. Focus is then handed to that one window once it exists --
never to the application -- and a window that landed on another Space anyway is
left alone rather than dragged into view.

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
