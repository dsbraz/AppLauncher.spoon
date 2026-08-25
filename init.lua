local obj = {}
obj.__index = obj

obj.name = "AppLauncher"
obj.version = "0.6.0"
obj.author = "Daniel Braz"
obj.license = "MIT"

obj.apps = {}
obj.newWindowMenuItem = { "File", "New Window" }
obj.newWindowFocusTimeout = 1.5
obj.newWindowFocusPoll = 0.05
obj.launchFocusTimeout = 1.5
obj.launchFocusPoll = 0.12
obj.launchFocusStableSamples = 2
obj.launchReactivateDelay = 0.5
obj.logger = hs.logger.new("AppLauncher")
obj._hotkeys = {}
obj._newWindowHotkeys = {}
obj._launchFocusTimers = {}
obj._windowFilters = {}
obj._windowFilterNames = {}

local function windowIsOnFocusedSpace(window)
  if not window or window:isMinimized() then return false end

  local ok, spaces = pcall(function() return hs.spaces.windowSpaces(window) end)
  if not ok or type(spaces) ~= "table" then return false end

  local focused = hs.spaces.focusedSpace()
  for _, space in ipairs(spaces) do
    if space == focused then return true end
  end
  return false
end

local function focusedSpaceWindow(app)
  local focused = app:focusedWindow()
  if windowIsOnFocusedSpace(focused) then return focused end

  for _, window in ipairs(app:allWindows()) do
    if window:isStandard() and windowIsOnFocusedSpace(window) then return window end
  end
end

function obj:_cancelLaunchFocus(role)
  local timer = self._launchFocusTimers[role]
  if timer then timer:stop() end
  self._launchFocusTimers[role] = nil
end

function obj:_clearWindowFilters()
  for _, filter in pairs(self._windowFilters) do filter:delete() end
  self._windowFilters = {}
  self._windowFilterNames = {}
end

function obj:_startWindowFilter(role, bundleID, app)
  local previous = self._windowFilters[role]
  if previous then previous:delete() end
  self._windowFilters[role] = nil
  self._windowFilterNames[role] = nil

  app = app or (bundleID and hs.application.applicationsForBundleID(bundleID)[1])
  local appName = (app and app:name())
    or (bundleID and hs.application.nameForBundleID(bundleID))

  if not appName then
    self.logger.w("Could not track windows for role: " .. tostring(role))
    return
  end

  local filter = hs.window.filter.new(false, "AppLauncher." .. role)
    :setAppFilter(appName, {})

  -- A subscription keeps the filter active, so it retains windows and their
  -- focus order as the user moves between Spaces.
  filter:subscribe(hs.window.filter.windowFocused, function() end)
  self._windowFilters[role] = filter
  self._windowFilterNames[role] = appName
end

function obj:_startWindowFilters(mapping)
  self:_clearWindowFilters()

  for role in pairs(mapping or {}) do
    self:_startWindowFilter(role, self.apps[role])
  end
end

function obj:_trackedWindows(role, app)
  if self._windowFilterNames[role] ~= app:name() then
    self:_startWindowFilter(role, self.apps[role], app)
  end

  local filter = self._windowFilters[role]
  if not filter then return {} end

  local windows = {}
  for _, window in ipairs(filter:getWindows(hs.window.filter.sortByFocusedLast)) do
    local owner = window:application()
    if owner and owner:pid() == app:pid() and window:isStandard() and not window:isMinimized() then
      table.insert(windows, window)
    end
  end
  return windows
end

function obj:_focusTrackedWindow(role, app, target)
  self:_cancelLaunchFocus(role)

  local deadline = hs.timer.absoluteTime() + self.launchFocusTimeout * 1e9
  local stableSamples = 0

  local function attempt()
    self._launchFocusTimers[role] = nil
    if not app:isRunning() then return end

    local ok = pcall(function() target:focus() end)
    if not ok then return self:_focusRunningApp(role, app) end

    local focused = hs.window.focusedWindow()
    if app:isFrontmost() and focused and focused:id() == target:id() then
      stableSamples = stableSamples + 1
    else
      stableSamples = 0
    end

    if stableSamples >= self.launchFocusStableSamples then return end

    if hs.timer.absoluteTime() < deadline then
      self._launchFocusTimers[role] = hs.timer.doAfter(self.launchFocusPoll, attempt)
    else
      self.logger.w("Could not stabilize tracked window for role: " .. tostring(role))
    end
  end

  attempt()
  return true
end

-- Application activation returns before a cross-Space animation has settled,
-- and it can choose an application window on another Space even when that app
-- already has a window here. Prefer a window in the focused Space. If there is
-- none, activate once to start the Space switch, then keep focusing the window
-- that appears there until it remains frontmost for two consecutive samples.
function obj:_focusRunningApp(role, app)
  self:_cancelLaunchFocus(role)

  local deadline = hs.timer.absoluteTime() + self.launchFocusTimeout * 1e9
  local nextActivation = 0
  local stableSamples = 0

  local function attempt()
    self._launchFocusTimers[role] = nil
    if not app:isRunning() then return end

    local window = focusedSpaceWindow(app)
    if window then
      window:focus()

      local focused = hs.window.focusedWindow()
      if app:isFrontmost() and focused and focused:id() == window:id() then
        stableSamples = stableSamples + 1
      else
        stableSamples = 0
      end

      if stableSamples >= self.launchFocusStableSamples then return end
    else
      stableSamples = 0
      local now = hs.timer.absoluteTime()
      if now >= nextActivation then
        app:activate(false)
        nextActivation = now + self.launchReactivateDelay * 1e9
      end
    end

    if hs.timer.absoluteTime() < deadline then
      self._launchFocusTimers[role] = hs.timer.doAfter(self.launchFocusPoll, attempt)
    else
      self.logger.w("Could not stabilize focus for role: " .. tostring(role))
    end
  end

  attempt()
  return true
end

function obj:_focusOrCycle(role, app)
  local windows = self:_trackedWindows(role, app)
  if #windows == 0 then return self:_focusRunningApp(role, app) end

  local focused = hs.window.focusedWindow()
  local focusedID = focused and focused:id()
  local target

  if app:isFrontmost() and #windows > 1 then
    -- The filter is ordered most-recently-focused first. Choosing the least
    -- recent window other than the current one rotates through the full set:
    -- after it receives focus, the previous windows all move down one place.
    for i = #windows, 1, -1 do
      if windows[i]:id() ~= focusedID then
        target = windows[i]
        break
      end
    end
  else
    -- Entering an app should not leave the current Space when it already has a
    -- window here. Among current-Space windows, preserve the filter's MRU order.
    for _, window in ipairs(windows) do
      if windowIsOnFocusedSpace(window) then
        target = window
        break
      end
    end
  end

  target = target or windows[1]
  return self:_focusTrackedWindow(role, app, target)
end

function obj:launch(role)
  local bundleID = self.apps[role]
  if not bundleID then
    self.logger.e("No application configured for role: " .. tostring(role))
    return false
  end

  local app = hs.application.applicationsForBundleID(bundleID)[1]
  if app then return self:_focusOrCycle(role, app) end

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
  for _, timer in pairs(self._launchFocusTimers) do timer:stop() end
  self._launchFocusTimers = {}
  self:_clearWindowFilters()
  return self:_clear("_hotkeys"):_clear("_newWindowHotkeys")
end

function obj:bindHotkeys(mapping)
  self:_startWindowFilters(mapping)
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
