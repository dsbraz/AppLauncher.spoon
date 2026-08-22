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
```

## Public API

- `launch(role)` launches or focuses the configured application.
- `bindHotkeys(mapping)` replaces the current bindings.
- `stop()` removes all bindings created by the Spoon.
- `status()` reports configured applications and bound roles.

## Requirements

- Hammerspoon 1.1.1 or newer
