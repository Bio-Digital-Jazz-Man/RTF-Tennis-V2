-- File: ServerScriptService/ProfileService.server.lua
-- Role:
--  • Create remotes (ProfileLoaded, ChangeSettings)
--  • Load per-player profile with retries; kick if we can't
--  • Keep profile in memory; apply settings patches during session only
--  • Save on PlayerRemoving and BindToClose (no mid-session writes)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

--== Remotes bootstrap ==--
local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not RemotesFolder then
	RemotesFolder = Instance.new("Folder")
	RemotesFolder.Name = "Remotes"
	RemotesFolder.Parent = ReplicatedStorage
end

local ProfileLoadedRE = RemotesFolder:FindFirstChild("ProfileLoaded")
if not ProfileLoadedRE then
	ProfileLoadedRE = Instance.new("RemoteEvent")
	ProfileLoadedRE.Name = "ProfileLoaded"
	ProfileLoadedRE.Parent = RemotesFolder
end

local ChangeSettingsRE = RemotesFolder:FindFirstChild("ChangeSettings")
if not ChangeSettingsRE then
	ChangeSettingsRE = Instance.new("RemoteEvent")
	ChangeSettingsRE.Name = "ChangeSettings"
	ChangeSettingsRE.Parent = RemotesFolder
end

--== DataStore & schema ==--
local STORE = DataStoreService:GetDataStore("PlayerProfiles_v1")

local DEFAULT_PROFILE = {
        settings = {
                PitchOffset = 18.0,
                CameraOffsetX = 0.0,
                CameraOffsetY = 2.0,
                CameraOffsetZ = 0.6,
        },
}

--== Utils ==--
local function deepCopy(tbl)
	if type(tbl) ~= "table" then return tbl end
	local c = {}
	for k, v in pairs(tbl) do
		c[k] = type(v) == "table" and deepCopy(v) or v
	end
	return c
end

local function reconcileProfile(saved)
	local base = deepCopy(DEFAULT_PROFILE)
	if type(saved) ~= "table" then
		return base
	end

	-- top-level
	for k, v in pairs(saved) do
		if k ~= "settings" then
			base[k] = v
		end
	end

	-- settings: merge, preserve unknowns, backfill defaults
	base.settings = base.settings or {}
	if type(saved.settings) == "table" then
		for sk, sv in pairs(saved.settings) do
			base.settings[sk] = sv
		end
	end
	for sk, sv in pairs(DEFAULT_PROFILE.settings) do
		if base.settings[sk] == nil then
			base.settings[sk] = sv
		end
	end

	return base
end

local function isPrimitive(v)
	local t = typeof(v)
	return t == "number" or t == "boolean" or t == "string"
end

local sessionProfiles: { [number]: table } = {}
local savingFlags: { [number]: boolean } = {}

local function keyFor(userId: number): string
	return "player_" .. tostring(userId)
end

local function loadProfileFor(player: Player): table?
	local userId = player.UserId
	local key = keyFor(userId)

	local attempts, backoff = 5, 1
	for i = 1, attempts do
		local ok, result = pcall(function()
			return STORE:GetAsync(key)
		end)
		if ok then
			return reconcileProfile(result)
		end
		if i < attempts then
			task.wait(backoff)
			backoff *= 2
		end
	end
	return nil
end

local function saveProfileFor(userId: number)
	if savingFlags[userId] then return end
	local profile = sessionProfiles[userId]
	if not profile then return end

	savingFlags[userId] = true
	local key = keyFor(userId)
	local attempts, backoff = 5, 1

	for i = 1, attempts do
		local ok, err = pcall(function()
			local snapshot = reconcileProfile(profile)
			STORE:UpdateAsync(key, function(_old)
				return snapshot
			end)
		end)
		if ok then
			savingFlags[userId] = false
			return
		end
		if i < attempts then
			task.wait(backoff)
			backoff *= 2
		else
			warn(("Final save failed for userId %d; data may be lost."):format(userId))
			savingFlags[userId] = false
		end
	end
end

--== Lifecycle ==--
local function onPlayerAdded(player: Player)
	local profile = loadProfileFor(player)
	if not profile then
		player:Kick("We couldn't load your data after multiple attempts. Please rejoin.")
		return
	end

	sessionProfiles[player.UserId] = profile
	ProfileLoadedRE:FireClient(player, deepCopy(profile))
end

local function onPlayerRemoving(player: Player)
	saveProfileFor(player.UserId)
	sessionProfiles[player.UserId] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

--== ChangeSettings remote handler ==--
-- Client sends { key = primitiveValue }
ChangeSettingsRE.OnServerEvent:Connect(function(player: Player, patch)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
        if type(patch) ~= "table" then return end
        local prof = sessionProfiles[player.UserId]
        if not prof then return end

        prof.settings = prof.settings or {}
        for key, value in pairs(patch) do
                if type(key) == "string" and isPrimitive(value) then
                        if key == "PitchOffset" and typeof(value) == "number" then
                                -- sanitize/clamp server-side
                                if value ~= value then value = DEFAULT_PROFILE.settings.PitchOffset end -- NaN guard
                                if value < -45 then value = -45 end
                                if value > 45 then value = 45 end
                                prof.settings[key] = value
                        elseif (key == "CameraOffsetX" or key == "CameraOffsetY" or key == "CameraOffsetZ") and typeof(value) == "number" then
                                if value ~= value then value = DEFAULT_PROFILE.settings[key] end -- NaN guard
                                if value < -5 then value = -5 end
                                if value > 5 then value = 5 end
                                prof.settings[key] = value
                        else
                                prof.settings[key] = value
                        end
                end
        end
	-- Not persisted here; only on leave or shutdown.
end)

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		saveProfileFor(p.UserId)
	end

	local t0 = os.clock()
	while true do
		local any = false
		for _, flag in pairs(savingFlags) do
			if flag then any = true break end
		end
		if not any or (os.clock() - t0) > 15 then break end
		task.wait(0.25)
	end
end)

