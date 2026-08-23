local obj = {}
obj.__index = obj

obj.name = "AppLauncher"
obj.version = "0.5.0"
obj.author = "Daniel Braz"
obj.license = "MIT"

obj.apps = {}
obj.newWindowMenuItem = { "File", "New Window" }
obj.newWindowFocusTimeout = 1.5
obj.newWindowFocusPoll = 0.05
obj.logger = hs.logger.new("AppLauncher")
obj._hotkeys = {}
obj._newWindowHotkeys = {}

function obj:launch(role)
  local bundleID = self.apps[role]
  if not bundleID then
    self.logger.e("No application configured for role: " .. tostring(role))
    return false
  end

  if hs.application.launchOrFocusByBundleID(bundleID) then return true end

  self.logger.e(string.format("Could not launch role %s (%s)", role, bundleID))
  hs.alert.show("Aplicativo não encontrado: " .. role)
  return false
end

-- Only a definite answer blocks the focus. A window reports no Space at all
-- for a moment after it is created, and treating that silence as "elsewhere"
-- meant the common case -- a window born right here -- never got focus.
local function knownToBeElsewhere(window)
  local ok, spaces = pcall(function() return hs.spaces.windowSpaces(window) end)
  if not ok or type(spaces) ~= "table" or #spaces == 0 then return false end

  local current = hs.spaces.focusedSpace()
  for _, space in ipairs(spaces) do
    if space == current then return false end
  end
  return true
end

-- The window does not exist yet when selectMenuItem returns, so focus cannot
-- be handed over synchronously. Focusing the application instead of this one
-- window is what would jump Spaces, so a window that landed elsewhere anyway
-- is left alone rather than dragged into view.
function obj:_focusNewWindow(app, existing)
  local deadline = hs.timer.absoluteTime() + self.newWindowFocusTimeout * 1e9

  local function attempt()
    for _, window in ipairs(app:allWindows()) do
      if not existing[window:id()] then
        if not knownToBeElsewhere(window) then window:focus() end
        return
      end
    end
    if hs.timer.absoluteTime() < deadline then
      hs.timer.doAfter(self.newWindowFocusPoll, attempt)
    end
  end

  hs.timer.doAfter(self.newWindowFocusPoll, attempt)
end

function obj:launchNewWindow(role)
  local bundleID = self.apps[role]
  if not bundleID then
    self.logger.e("No application configured for role: " .. tostring(role))
    return false
  end

  local app = hs.application.applicationsForBundleID(bundleID)[1]
  if not app then return self:launch(role) end

  local existing = {}
  for _, window in ipairs(app:allWindows()) do existing[window:id()] = true end

  -- Selecting the menu item through Accessibility does not need the
  -- application frontmost, and must not have it: activating an application
  -- with windows on another Space sends macOS to that Space, and the new
  -- window is then born there rather than where the shortcut was pressed.
  if app:selectMenuItem(self.newWindowMenuItem) then
    self:_focusNewWindow(app, existing)
    return true
  end

  -- A browser or a terminal always publishes this item, so reaching here means
  -- the configured application or the menu path is wrong. Say so instead of
  -- quietly focusing, which would hide the misconfiguration.
  local path = table.concat(self.newWindowMenuItem, " > ")
  self.logger.e(string.format("No %s menu item for role %s (%s)", path, role, bundleID))
  hs.alert.show(string.format("%s: sem %s", role, path))
  return false
end

-- The two sets of bindings differ only in which table holds them and which
-- method they call, so they share the binding and the tearing down. `method`
-- is looked up on self at press time, not captured here, so overriding one
-- still works.
function obj:_clear(store)
  for _, hotkey in pairs(self[store] or {}) do hotkey:delete() end
  self[store] = {}
  return self
end

function obj:_bind(store, mapping, method)
  self:_clear(store)

  for role, spec in pairs(mapping or {}) do
    local targetRole = role
    local hotkey = hs.hotkey.bind(spec[1], spec[2], function()
      self[method](self, targetRole)
    end)

    if hotkey then
      self[store][role] = hotkey
    else
      self.logger.e(string.format("Could not bind %s for role: %s", method, tostring(role)))
    end
  end

  return self
end

function obj:stop()
  return self:_clear("_hotkeys"):_clear("_newWindowHotkeys")
end

function obj:bindHotkeys(mapping)
  return self:_bind("_hotkeys", mapping, "launch")
end

-- Plain hotkeys, one per role. A prefix mode was tried first and had a failure
-- mode with no way back: entering it disables the prefix key by design, so a
-- role key that reached the global binding instead of the mode's own left the
-- mode entered forever and the prefix dead until a reload.
function obj:bindNewWindow(mapping)
  return self:_bind("_newWindowHotkeys", mapping, "launchNewWindow")
end

local function sortedRoles(hotkeys)
  local roles = {}
  for role in pairs(hotkeys or {}) do table.insert(roles, role) end
  table.sort(roles)
  return roles
end

function obj:status()
  return {
    apps = self.apps,
    bound = sortedRoles(self._hotkeys),
    newWindow = sortedRoles(self._newWindowHotkeys),
    version = self.version,
  }
end

return obj
