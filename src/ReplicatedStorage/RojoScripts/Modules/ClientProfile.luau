-- File: ReplicatedStorage/ClientProfile.module.lua
-- Role: client-side source of truth + helpers
-- This version keeps normal profile data in _data,
-- and also exposes Instances for settings values.

local ClientProfile = {}
local _data = nil

local NUMBER_SETTING_DEFAULTS = {
        PitchOffset = 18.0,
        CameraOffsetX = 0.0,
        CameraOffsetY = 2.0,
        CameraOffsetZ = 0.6,
}

-- Instances for settings (can be read directly)
ClientProfile.SettingsFolder = Instance.new("Folder")
ClientProfile.SettingsFolder.Name = "Settings"
ClientProfile.SettingsFolder.Parent = script

for settingName, defaultValue in pairs(NUMBER_SETTING_DEFAULTS) do
        local numberValue = Instance.new("NumberValue")
        numberValue.Name = settingName
        numberValue.Value = defaultValue
        numberValue.Parent = ClientProfile.SettingsFolder
        ClientProfile[settingName] = numberValue
end

local function deepCopy(tbl)
	if type(tbl) ~= "table" then return tbl end
	local c = {}
	for k, v in pairs(tbl) do
		c[k] = type(v) == "table" and deepCopy(v) or v
	end
	return c
end

function ClientProfile.IsLoaded()
	return _data ~= nil
end

function ClientProfile.WaitUntilLoaded(timeoutSeconds)
	if type(timeoutSeconds) ~= "number" then timeoutSeconds = nil end
	local start = os.clock()
	while not _data do
		if timeoutSeconds and (os.clock() - start) > timeoutSeconds then
			return false
		end
		task.wait()
	end
	return true
end

function ClientProfile.Get()
	return _data
end

local function resolveSettingValue(settingsTable: table?, settingName: string)
        if type(settingsTable) == "table" then
                local raw = settingsTable[settingName]
                if raw ~= nil then
                        local n = tonumber(raw)
                        if n then
                                return n
                        end
                end
        end
        return NUMBER_SETTING_DEFAULTS[settingName]
end

function ClientProfile.SetFromServer(profileTable)
        _data = deepCopy(profileTable)

        for settingName, defaultValue in pairs(NUMBER_SETTING_DEFAULTS) do
                local numberValue = ClientProfile[settingName]
                if typeof(numberValue) == "Instance" and numberValue:IsA("NumberValue") then
                        local newValue = resolveSettingValue(_data and _data.settings, settingName)
                        if typeof(newValue) ~= "number" then
                                newValue = defaultValue
                        end
                        numberValue.Value = newValue
                end
        end
end

function ClientProfile.ApplySettingsPatchLocally(patch)
        if type(patch) ~= "table" or not _data then return end
        _data.settings = _data.settings or {}
        for k, v in pairs(patch) do
                _data.settings[k] = v
                if type(v) == "number" and NUMBER_SETTING_DEFAULTS[k] ~= nil then
                        local numberValue = ClientProfile[k]
                        if typeof(numberValue) == "Instance" and numberValue:IsA("NumberValue") then
                                numberValue.Value = v
                        end
                end
        end
end

return ClientProfile

