-- DataController.luau
-- Handles data loading, storing, and migration functionality

local DataController = {}
DataController.__index = DataController

function DataController:Log(...)
	if self.ServerManager and self.ServerManager.Log then
		self.ServerManager:Log(...)
	else
		print(...)
	end
end

local ProfileService = require(script.Parent.Parent.dependencies.ProfileService)

local DEFAULT_PROFILE = {
	time_played_secs = 0,
	last_seen = 0,
	player_stats = {
		matches_won = 0,
		ELO = 1200,
	},
	user_settings = {},
}

-- Loaded fresh at these values for every player at the start of sessions; useful for persistent player-related cross-controller data
local SESSION_TEMPLATE = {
	CurrentQueue = nil,
	CurrentMatch = nil,
	loaded = false,
}

local GameProfileStore = ProfileService.GetProfileStore("PlayerData_DEVELOPMENT_0", DEFAULT_PROFILE)

function DataController.new(ServerManager)
	local self = setmetatable({}, DataController)
	self.ServerManager = ServerManager
	self.RemoteController = ServerManager.RemoteController

	self:Log("DataController initializing")

	self.Profiles = {}
	self.SessionDatas = {}
	self._sessionDataReadySignals = {}
	self.JoinTimes = {}

	return self
end

local function cloneTable(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == "table" then -- recursive
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[cloneTable(orig_key)] = cloneTable(orig_value)
		end
		setmetatable(copy, cloneTable(getmetatable(orig)))
	else -- number, string, boolean, etc
		copy = orig
	end
	return copy
end

function DataController:TryToLoad(player) -- Expected to kick the player due to failure or return a valid profile
	self:Log("Loading profile for", player.Name)
	self.JoinTimes[player] = os.time()
	local psProfile = GameProfileStore:LoadProfileAsync("Player_" .. player.UserId)
	if psProfile ~= nil then
		psProfile:AddUserId(player.UserId) -- GDPR compliance
		psProfile:Reconcile() -- Fill in missing variables from ProfileTemplate (optional)
		psProfile:ListenToRelease(function()
			self.Profiles[player] = nil
			-- The profile could've been loaded on another Roblox server; kick the player
			player:Kick()
		end)
		if player:IsDescendantOf(game.Players) == true then
			self:Log("Profile loaded for", player.Name)
			self.Profiles[player] = psProfile
			-- Store their session data
			self.SessionDatas[player] = cloneTable(SESSION_TEMPLATE)
			if self._sessionDataReadySignals[player] then
				self._sessionDataReadySignals[player]:Fire(self.SessionDatas[player])
				self._sessionDataReadySignals[player]:Destroy()
				self._sessionDataReadySignals[player] = nil
			end
			return self.Profiles[player]
		else
			-- Player left before the profile loaded:
			psProfile:Release()
		end
	else
		-- The profile couldn't be loaded possibly due to other
		--   Roblox servers trying to load this profile at the same time:
		player:Kick("Error 67: Please try again in a few minutes.")
		self:Log("Failed to load profile for", player.Name)
	end
end

-- Returns a reference to the player's session data
function DataController:GetSessionData(player)
	return self.SessionDatas[player]
end

function DataController:CleanSessionData(player)
	self.SessionDatas[player] = nil
end

function DataController:WaitForSessionData(player)
	if self.SessionDatas[player] then
		return self.SessionDatas[player]
	end

	if not self._sessionDataReadySignals[player] then
		local bindable = Instance.new("BindableEvent")
		self._sessionDataReadySignals[player] = bindable
	end

	return self._sessionDataReadySignals[player].Event:Wait()
end

function DataController:SaveOnLeave(player, profileData)
	local profile = self.Profiles[player]
	-- Erase their session data
	self:CleanSessionData(player)
	if profile ~= nil then
		self:Log("Releasing profile for", player.Name)
		profile:Release()
	else
		warn("Not saving " .. player.Name .. "'s data because it is not loaded yet.")
	end
end

function DataController:EnsureDefaultKeys(playerProfile)
	for key, value in pairs(DEFAULT_PROFILE) do
		if playerProfile[key] == nil then
			playerProfile[key] = cloneTable(value)
		end
	end
end

function DataController:TrySetup(playerProfile)
	-- Do first time setup stuff here
	if playerProfile.created == 0 then
		playerProfile.created = DateTime.now().UnixTimestamp
	end
end

function DataController:IncrementTimePlayedSecs(player)
	-- Assumed to be called on player leaving
	self:GetPlayerData(player).time_played_secs += (os.time() - self.JoinTimes[player])
end

function DataController:SetLastSeen(player)
	self:GetPlayerData(player).last_seen = DateTime.now().UnixTimestamp
end

function DataController:GetPlayerData(player)
	local retval = nil
	retval = self.Profiles[player]["Data"]
	return retval
end

function DataController:GetPlayerProfile(player)
	local retval = nil
	retval = self.Profiles[player]
	return retval
end

function DataController:DumpPlayerData(player)
	local profile = self:GetPlayerProfile(player)
	if profile then
		local http = game:GetService("HttpService")
		local encoded = http:JSONEncode(profile.Data)
		self:Log("Data dump for", player.Name, encoded)
		return encoded
	end
	self:Log("No profile to dump for", player.Name)
	return nil
end

function DataController:ClearPlayerQueue(player: Player)
    local sessionData = self:GetSessionData(player)
    if sessionData and sessionData.CurrentQueue then
        print(("[Queue] Clearing queue for %s"):format(player.Name))
        sessionData.CurrentQueue = nil
    end
end

function DataController:ClearPlayerMatch(player: Player)
    local sessionData = self:GetSessionData(player)
    if sessionData and sessionData.CurrentMatch then
        print(("[Queue] Clearing match for %s"):format(player.Name))
        sessionData.CurrentMatch = nil
    end
end

function DataController:SetPlayerQueue(player: Player, Queue)
    local sessionData = self:GetSessionData(player)
    if sessionData then
        print(("[Queue] Setting queue for %s"):format(player.Name))
        sessionData.CurrentQueue = Queue
    end
end

function DataController:SetPlayerMatch(player: Player, Match)
    local sessionData = self:GetSessionData(player)
    if sessionData then
        print(("[Queue] Setting CurrentMatch for %s"):format(player.Name))
        sessionData.CurrentMatch = Match
    end
end

function DataController:IncrementMatchesWon(player: Player)
	local data = self:GetPlayerData(player)
	if data and data.player_stats then
		data.player_stats.matches_won += 1
	end
end

local ELO_K = 32

function DataController:RecomputeELOs(playerWon: Player, playerLost: Player)
    print(("[ELO] Recomputing ELOs for %s (WINNER) vs %s (LOSER)")
        :format(playerWon.Name, playerLost.Name))

    local dataW = self:GetPlayerData(playerWon)
    local dataL = self:GetPlayerData(playerLost)

    if not (dataW and dataL) then
        warn("[ELO] Could not find player data for one or both players.")
        return
    end

    local Ra = dataW.player_stats.ELO
    local Rb = dataL.player_stats.ELO

    print(("[ELO] Current ratings: %s=%d, %s=%d")
        :format(playerWon.Name, Ra, playerLost.Name, Rb))

    local Ea = 1 / (1 + 10 ^ ((Rb - Ra) / 400))
    local Eb = 1 / (1 + 10 ^ ((Ra - Rb) / 400))

    print(("[ELO] Expected scores: %s=%.3f, %s=%.3f")
        :format(playerWon.Name, Ea, playerLost.Name, Eb))

    -- Winner gets score 1, loser gets 0
    local newRa = Ra + ELO_K * (1 - Ea)
    local newRb = Rb + ELO_K * (0 - Eb)

    dataW.player_stats.ELO = math.floor(newRa + 0.5)
    dataL.player_stats.ELO = math.floor(newRb + 0.5)

    print(("[ELO] New ratings: %s=%d (Δ%d), %s=%d (Δ%d)")
        :format(
            playerWon.Name, dataW.player_stats.ELO, dataW.player_stats.ELO - Ra,
            playerLost.Name, dataL.player_stats.ELO, dataL.player_stats.ELO - Rb
        ))
end


return DataController
