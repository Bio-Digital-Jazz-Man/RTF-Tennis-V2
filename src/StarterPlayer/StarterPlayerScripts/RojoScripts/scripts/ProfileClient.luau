-- File: StarterPlayer/StarterPlayerScripts/ProfileClient.local.lua
-- Role:
--  • Receive initial profile snapshot from server and store in ClientProfile
--  • Provide a small API other LocalScripts can require to send settings patches

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ProfileLoadedRE = Remotes:WaitForChild("ProfileLoaded")
local ChangeSettingsRE = Remotes:WaitForChild("ChangeSettings")

local ClientProfile = require(ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("ClientProfile"))

ProfileLoadedRE.OnClientEvent:Connect(function(serverProfile)
	ClientProfile.SetFromServer(serverProfile)
end)

local function ChangeSettings(patch: table)
	if type(patch) ~= "table" then return end
	ClientProfile.ApplySettingsPatchLocally(patch) -- optimistic update
	ChangeSettingsRE:FireServer(patch)             -- authoritative validation server-side
end

return {
	ChangeSettings = ChangeSettings,
}
