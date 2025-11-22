-- PlayersController.luau
-- Handles joining, spawning, and ensuring no player collision

local Players = game:GetService("Players")
local GAME_OWNER_ID = 4987671

local PlayersController = {}
PlayersController.__index = PlayersController

function PlayersController:Log(...)
	if self.ServerManager and self.ServerManager.Log then
		self.ServerManager:Log(...)
	else
		print(...)
	end
end

function PlayersController.new(ServerManager)
	local self = setmetatable({}, PlayersController)
	self.ServerManager = ServerManager
	self.RemoteController = ServerManager.RemoteController
	self.DataController = ServerManager.DataController

	self:Log("PlayersController initialized")

	self:SetupListeners()
	return self
end

function PlayersController:SetupListeners()
	self:Log("Setting up player listeners")
	Players.PlayerAdded:Connect(function(player)
		self:ProcessJoinedPlayer(player)
		if player.UserId == GAME_OWNER_ID then
			player.Chatted:Connect(function(msg)
				if msg == "!datadump" then
					self:Log("Datadump requested by", player.Name)
					self.DataController:DumpPlayerData(player)
				end
			end)
		end
	end)

	-- Handle players already in-game
	for _, player in ipairs(Players:GetPlayers()) do
		self:ProcessJoinedPlayer(player)
		if player.UserId == GAME_OWNER_ID then
			player.Chatted:Connect(function(msg)
				if msg == "!datadump" then
					self:Log("Datadump requested by", player.Name)
					self.DataController:DumpPlayerData(player)
				end
			end)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		self:Log("Player removing", player.Name)
		self:ProcessRemovingPlayer(player)
	end)
end

function PlayersController:ProcessRemovingPlayer(player)
	self:Log("Removing", player.Name)

	-- Dispatch to the need-to-knowers
	local ok1, err1 = pcall(function()
		local plrSD = self.DataController:GetSessionData(player)
		if plrSD.CurrentQueue then
			plrSD.CurrentQueue:RemovePlayer(player)
		end
		if plrSD.CurrentMatch then
			plrSD.CurrentMatch:RemovePlayer(player)
		end
	end)
	if not ok1 then
		warn(err1, "ProcessRemovingPlayer: could not dispatch for ", player.Name)
	else
		self:Log("Removing dispatch done for", player.Name)
	end

	local ok, err = pcall(function()
		self.DataController:SetLastSeen(player)
		self.DataController:IncrementTimePlayedSecs(player)
		self.DataController:SaveOnLeave(player)
		self.DataController.JoinTimes[player] = nil
		self.DataController.Profiles[player] = nil
	end)
	if not ok then
		warn(err, "ProcessRemovingPlayer: could not clean up for ", player.Name)
	else
		self:Log("Cleanup done for", player.Name)
	end
end

function PlayersController:ProcessJoinedPlayer(player)
	self:Log("Player joined", player.Name)
	local ok, err = pcall(function()
		self.DataController:TryToLoad(player)
		self:Log("Finished join for", player.Name)
	end)
	if not ok then
		player:Kick("Data failed to load. Try again in a few minutes.")
		warn("ProcessJoinedPlayer error:", err)
	end
end

return PlayersController
