local obj = {}
obj.__index = obj

obj.name = "AppLauncher"
obj.version = "0.1.0"
obj.author = "Daniel Braz"
obj.license = "MIT"

obj.apps = {}
obj.logger = hs.logger.new("AppLauncher")
obj._hotkeys = {}

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

function obj:stop()
  for _, hotkey in pairs(self._hotkeys) do hotkey:delete() end
  self._hotkeys = {}
  return self
end

function obj:bindHotkeys(mapping)
  self:stop()

  for role, spec in pairs(mapping or {}) do
    local targetRole = role
    local hotkey = hs.hotkey.bind(spec[1], spec[2], function()
      self:launch(targetRole)
    end)

    if hotkey then
      self._hotkeys[role] = hotkey
    else
      self.logger.e("Could not bind hotkey for role: " .. tostring(role))
    end
  end

  return self
end

function obj:status()
  local bound = {}
  for role in pairs(self._hotkeys) do table.insert(bound, role) end
  table.sort(bound)

  return {
    apps = self.apps,
    bound = bound,
    version = self.version,
  }
end

return obj
