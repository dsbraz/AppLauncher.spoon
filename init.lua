local obj = {}
obj.__index = obj

obj.name = "AppLauncher"
obj.version = "0.8.0"
obj.author = "Daniel Braz"
obj.license = "MIT"

obj.apps = {}
obj.newWindowMenuItem = { "File", "New Window" }
obj.newWindowMenuItems = {}
obj.newWindowFocusTimeout = 1.5
obj.newWindowFocusPoll = 0.05
obj.joinNewWindowsToCurrentStage = false
obj.stageManagerSourceStabilityDelay = 0.12
obj.stageManagerStabilityDelay = 0.18
obj.stageManagerJoinTimeout = 4
obj.stageManagerJoinPoll = 0.12
obj.stageManagerJoinStableSamples = 2
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
obj._stageManagerOperations = {}
obj._stageManagerOperationID = 0

local STAGE_MANAGER_BUNDLE_ID = "com.apple.WindowManager"
local ADD_TO_STAGE_ACTION = "AXAddToStage"

local function contains(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

local function windowIsOnSpace(window, wantedSpace)
  local ok, spaces = pcall(function() return hs.spaces.windowSpaces(window) end)
  if not ok or type(spaces) ~= "table" then return false end
  return contains(spaces, wantedSpace)
end

local function stageManagerEnabled()
  local output, ok = hs.execute(
    "/usr/bin/defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null"
  )
  return ok and tonumber(output) == 1
end

local function stageManagerButtons()
  local app = hs.application.applicationsForBundleID(STAGE_MANAGER_BUNDLE_ID)[1]
  if not app then return nil end

  local ok, root = pcall(function() return hs.axuielement.applicationElement(app) end)
  if not ok or not root then return nil end

  local buttons = {}
  local function walk(element, depth)
    if depth > 8 then return end

    local roleOK, role = pcall(function() return element:attributeValue("AXRole") end)
    if roleOK and role == "AXButton" then
      local idsOK, ids = pcall(function() return element:attributeValue("AXWindowsIDs") end)
      local actionsOK, actions = pcall(function() return element:actionNames() end)
      if idsOK and type(ids) == "table" and actionsOK and contains(actions, ADD_TO_STAGE_ACTION) then
        table.insert(buttons, { element = element, windowIDs = ids })
      end
    end

    local childrenOK, children = pcall(function() return element:attributeValue("AXChildren") end)
    if childrenOK and type(children) == "table" then
      for _, child in ipairs(children) do walk(child, depth + 1) end
    end
  end

  walk(root, 0)
  return buttons
end

local function inactiveStageWindowIDs(buttons)
  local ids = {}
  for _, button in ipairs(buttons or {}) do
    for _, windowID in ipairs(button.windowIDs) do ids[windowID] = true end
  end
  return ids
end

local function stageButtonsSignature(buttons)
  local groups = {}
  for _, button in ipairs(buttons or {}) do
    local ids = {}
    for _, windowID in ipairs(button.windowIDs) do table.insert(ids, windowID) end
    table.sort(ids)
    table.insert(groups, table.concat(ids, ","))
  end
  table.sort(groups)
  return table.concat(groups, "|")
end

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

function obj:_newStageManagerOperation()
  self._stageManagerOperationID = self._stageManagerOperationID + 1
  local operation = { id = self._stageManagerOperationID }
  self._stageManagerOperations[operation.id] = operation
  return operation
end

function obj:_scheduleStageManagerOperation(operation, delay, callback)
  if operation.finished then return end
  if operation.timer then operation.timer:stop() end

  operation.timer = hs.timer.doAfter(delay, function()
    operation.timer = nil
    if not operation.finished then callback() end
  end)
end

function obj:_finishStageManagerOperation(operation)
  if not operation or operation.finished then return end
  operation.finished = true
  if operation.timer then operation.timer:stop() end
  operation.timer = nil
  self._stageManagerOperations[operation.id] = nil
end

function obj:_captureStableStageContext(operation, callback)
  local space = hs.spaces.focusedSpace()
  local focused = hs.window.focusedWindow()
  local focusedID = focused and focused:isStandard() and focused:id()
  if not space or not focusedID then return callback(nil) end

  local context = {
    focusedWindowID = focusedID,
    space = space,
  }

  local function confirm()
    local current = hs.window.focusedWindow()
    if hs.spaces.focusedSpace() == space and current and current:id() == focusedID then
      return callback(context)
    end
    callback(nil)
  end

  self:_scheduleStageManagerOperation(operation, self.stageManagerSourceStabilityDelay, confirm)
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

function obj:_finishStageManagerJoin(operation, context, window, warning, focusWindow)
  if warning then self.logger.w(warning) end

  if focusWindow
    and hs.spaces.focusedSpace() == context.space
    and windowIsOnSpace(window, context.space)
  then
    pcall(function() window:focus() end)
  end
  self:_finishStageManagerOperation(operation)
end

function obj:_joinStageManagerContext(operation, context, window)
  local deadline = hs.timer.absoluteTime() + self.stageManagerJoinTimeout * 1e9
  local stableSignature
  local stableSamples = 0
  local readySignature
  local readySamples = 0
  local newWindowStableSamples = 0
  local actionSent = false
  local sourceWindow = hs.window.get(context.focusedWindowID)
  local phase = "settleNewWindow"

  if not sourceWindow or not windowIsOnSpace(sourceWindow, context.space) then
    return self:_finishStageManagerOperation(operation)
  end

  -- Opening a window gives it a stage of its own. First let that automatic focus
  -- settle; otherwise the application's delayed focus can override the attempt
  -- to return to the original stage. Then add only the new window from its
  -- inactive pile, keeping the original group intact.
  pcall(function() window:focus() end)

  local function attempt()
    if hs.spaces.focusedSpace() ~= context.space then
      return self:_finishStageManagerOperation(operation)
    end

    if hs.timer.absoluteTime() >= deadline then
      return self:_finishStageManagerJoin(
        operation,
        context,
        window,
        "Timed out while joining a new window to the current Stage Manager group",
        false
      )
    end

    local buttons = stageManagerButtons()
    if not buttons then
      return self:_scheduleStageManagerOperation(operation, self.stageManagerJoinPoll, attempt)
    end

    local inactive = inactiveStageWindowIDs(buttons)
    local signature = stageButtonsSignature(buttons)
    local focused = hs.window.focusedWindow()
    local focusedID = focused and focused:id()
    local newWindowButton
    for _, button in ipairs(buttons) do
      for _, windowID in ipairs(button.windowIDs) do
        if windowID == window:id() then
          newWindowButton = button
          break
        end
      end
      if newWindowButton then break end
    end

    if phase == "settleNewWindow" then
      if focusedID == window:id() and not inactive[window:id()] then
        newWindowStableSamples = newWindowStableSamples + 1
      else
        newWindowStableSamples = 0
      end

      if newWindowStableSamples >= 2 then
        phase = "restoreSourceStage"
        readySignature = nil
        readySamples = 0
        pcall(function() sourceWindow:focus() end)
      end
      return self:_scheduleStageManagerOperation(operation, self.stageManagerStabilityDelay, attempt)
    end

    if not actionSent then
      if focusedID ~= context.focusedWindowID or inactive[context.focusedWindowID] then
        readySignature = nil
        readySamples = 0
        return self:_scheduleStageManagerOperation(operation, self.stageManagerJoinPoll, attempt)
      end

      -- An empty list is a normal transient state during the stage animation,
      -- not proof that macOS grouped the windows automatically. Require the new
      -- window's inactive pile to appear before treating the tree as actionable.
      if not newWindowButton then
        readySignature = nil
        readySamples = 0
        return self:_scheduleStageManagerOperation(operation, self.stageManagerJoinPoll, attempt)
      end

      if signature == readySignature then
        readySamples = readySamples + 1
      else
        readySignature = signature
        readySamples = 1
      end
      if readySamples < 2 then
        return self:_scheduleStageManagerOperation(operation, self.stageManagerStabilityDelay, attempt)
      end

      local actionOK, result = pcall(function()
        return newWindowButton.element:performAction(ADD_TO_STAGE_ACTION)
      end)
      if not actionOK or result == false then
        return self:_finishStageManagerJoin(
          operation,
          context,
          window,
          "WindowManager rejected AXAddToStage",
          false
        )
      end
      actionSent = true
      stableSignature = nil
      stableSamples = 0
      return self:_scheduleStageManagerOperation(operation, self.stageManagerStabilityDelay, attempt)
    end

    if not inactive[context.focusedWindowID] and not inactive[window:id()] then
      if signature == stableSignature then
        stableSamples = stableSamples + 1
      else
        stableSignature = signature
        stableSamples = 1
      end
    else
      stableSignature = nil
      stableSamples = 0
    end

    if stableSamples >= self.stageManagerJoinStableSamples then
      return self:_finishStageManagerJoin(operation, context, window, nil, true)
    end
    self:_scheduleStageManagerOperation(operation, self.stageManagerStabilityDelay, attempt)
  end

  self:_scheduleStageManagerOperation(operation, self.stageManagerStabilityDelay, attempt)
end

function obj:_waitForStageManagerWindow(operation, context, bundleID, existing)
  local deadline = hs.timer.absoluteTime() + self.newWindowFocusTimeout * 1e9

  local function attempt()
    local app = hs.application.applicationsForBundleID(bundleID)[1]
    if app then
      for _, window in ipairs(app:allWindows()) do
        if window:isStandard() and not existing[window:id()] then
          if windowIsOnSpace(window, context.space) or not knownToBeElsewhere(window) then
            return self:_joinStageManagerContext(operation, context, window)
          end
          return self:_finishStageManagerOperation(operation)
        end
      end
    end

    if hs.timer.absoluteTime() >= deadline then
      self.logger.w("Could not find the new window for Stage Manager grouping")
      return self:_finishStageManagerOperation(operation)
    end
    self:_scheduleStageManagerOperation(operation, self.newWindowFocusPoll, attempt)
  end

  self:_scheduleStageManagerOperation(operation, self.newWindowFocusPoll, attempt)
end

function obj:_openNewWindow(role, bundleID, context, operation)
  local app = hs.application.applicationsForBundleID(bundleID)[1]
  local existing = {}
  if app then
    for _, window in ipairs(app:allWindows()) do existing[window:id()] = true end
  end

  local opened
  if app then
    local menuItem = self.newWindowMenuItems[role] or self.newWindowMenuItem

    -- Selecting the menu item through Accessibility does not need the
    -- application frontmost, and must not have it: activating an application
    -- with windows on another Space sends macOS to that Space, and the new
    -- window is then born there rather than where the shortcut was pressed.
    opened = app:selectMenuItem(menuItem)
    if not opened then
      local path = table.concat(menuItem, " > ")
      self.logger.e(string.format("No %s menu item for role %s (%s)", path, role, bundleID))
      hs.alert.show(string.format("%s: sem %s", role, path))
    end
  else
    -- A first launch creates the application's initial window instead of
    -- selecting a menu item, but it can still be joined to the saved stage.
    opened = hs.application.launchOrFocusByBundleID(bundleID)
    if not opened then
      self.logger.e(string.format("Could not launch role %s (%s)", role, bundleID))
      hs.alert.show("Aplicativo não encontrado: " .. role)
    end
  end

  if not opened then
    self:_finishStageManagerOperation(operation)
    return false
  end

  if context then
    self:_waitForStageManagerWindow(operation, context, bundleID, existing)
  elseif app then
    self:_focusNewWindow(app, existing)
  end
  return true
end

function obj:launchNewWindow(role)
  local bundleID = self.apps[role]
  if not bundleID then
    self.logger.e("No application configured for role: " .. tostring(role))
    return false
  end

  if not self.joinNewWindowsToCurrentStage or not stageManagerEnabled() then
    return self:_openNewWindow(role, bundleID)
  end

  local operation = self:_newStageManagerOperation()
  self:_captureStableStageContext(operation, function(context)
    if context then
      self:_openNewWindow(role, bundleID, context, operation)
    else
      self:_finishStageManagerOperation(operation)
      self:_openNewWindow(role, bundleID)
    end
  end)
  return true
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
  for _, operation in pairs(self._stageManagerOperations) do
    operation.finished = true
    if operation.timer then operation.timer:stop() end
  end
  self._stageManagerOperations = {}
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
    joinNewWindowsToCurrentStage = self.joinNewWindowsToCurrentStage,
    newWindow = sortedRoles(self._newWindowHotkeys),
    version = self.version,
  }
end

return obj
