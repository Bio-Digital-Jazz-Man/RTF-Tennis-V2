local Types = require(script.Parent.Types)
local Match = require(script.Parent.Match)

local Queue = {}
Queue.__index = Queue

export type Queue = {
	Queue: { Player },
	CountdownId: number,
	CountdownLength: number,
	_Court: Types.Court?,
	InfoLabel: TextLabel?,
	ServerManager: any,
	MaxPlayers: number,
	MatchInProgress: boolean,
	new: (court: Types.Court?, ServerManager: any, maxPlayers: number?) -> Queue,
	AddPlayer: (self: Queue, player: Player) -> boolean,
	RemovePlayer: (self: Queue, player: Player) -> boolean,
	TryStart: (self: Queue, court: Types.Court?) -> (),
	SafetyCheck: (self: Queue) -> (),
	Clear: (self: Queue) -> (),
	Destroy: (self: Queue) -> (),
	SetInfoLabel: (self: Queue, label: TextLabel) -> (),
	UpdateInfoLabel: (self: Queue, countdownRemaining: number?) -> (),
}

local function isValidPlayer(p: any): boolean
	return typeof(p) == "Instance" and p:IsA("Player") and p.Parent ~= nil
end

function Queue.new(court: Types.Court?, ServerManager, maxPlayers: number?): Queue
	local self = setmetatable({}, Queue) :: any

	self.Queue = {}
	self.CountdownId = 0
	self.CountdownLength = 5
	self._Court = court
	self.InfoLabel = nil
	self.ServerManager = ServerManager
	self.MaxPlayers = maxPlayers or 2
	self.MatchInProgress = false

	return self
end

function Queue:UpdateInfoLabel(countdownRemaining: number?)
	if not self.InfoLabel then
		return
	end

	if self.MatchInProgress then
		self.InfoLabel.Text = "Match in Progress"
		return
	end

	local p1 = self.Queue[1]
	local p2 = self.Queue[2]

	local p1Name = (isValidPlayer(p1) and p1.Name) or "Empty"
	local p2Name = (isValidPlayer(p2) and p2.Name) or "Empty"

	local newText = string.format("%s | %s", p1Name, p2Name)
	if countdownRemaining and countdownRemaining > 0 then
		newText ..= string.format("  Starting in: %d", countdownRemaining)
	end

	self.InfoLabel.Text = newText
end

function Queue:SafetyCheck()
	local toRemove = {}
	for i, qPlayer in ipairs(self.Queue) do
		if not isValidPlayer(qPlayer) then
			table.insert(toRemove, i)
		end
	end
	for i = #toRemove, 1, -1 do
		table.remove(self.Queue, toRemove[i])
	end

	if #self.Queue < self.MaxPlayers then
		self.CountdownId += 1
	end

	self:UpdateInfoLabel()
end

-- Adds a player if possible, ignores if full or match active
function Queue:AddPlayer(player: Player): boolean
	if not isValidPlayer(player) then
		return false
	end

	if self.MatchInProgress then
		return false
	end

	local psd = self.ServerManager.DataController:GetSessionData(player)
	if psd.CurrentQueue then
		return false
	end

	if #self.Queue >= self.MaxPlayers then
		return false
	end

	for _, qPlayer in ipairs(self.Queue) do
		if qPlayer == player then
			return false
		end
	end

	table.insert(self.Queue, player)
	psd.CurrentQueue = self

	if #self.Queue >= self.MaxPlayers then
		self:TryStart(self._Court)
	end

	self:UpdateInfoLabel()
	return true
end

-- Removes a player if they were actually in queue
function Queue:RemovePlayer(player: Player): boolean
	if self.MatchInProgress then
		return false
	end

	local wasInQueue = false
	for i, qPlayer in ipairs(self.Queue) do
		if qPlayer == player then
			table.remove(self.Queue, i)
			wasInQueue = true
			break
		end
	end

	if not wasInQueue then
		return false
	end

	local psd = self.ServerManager.DataController:GetSessionData(player)
	if psd then
		psd.CurrentQueue = nil
	end

	if #self.Queue < self.MaxPlayers then
		self.CountdownId += 1
	end

	self:UpdateInfoLabel()
	return true
end

function Queue:TryStart(court: Types.Court?)
	self:SafetyCheck()
	if #self.Queue < self.MaxPlayers or self.MatchInProgress then
		return
	end

	self.CountdownId += 1
	local myId = self.CountdownId
	local countdownSeconds = self.CountdownLength

	task.spawn(function()
		local t = countdownSeconds
		while t > 0 do
			if myId ~= self.CountdownId then
				return
			end
			if #self.Queue < self.MaxPlayers then
				return
			end
			if not (isValidPlayer(self.Queue[1]) and isValidPlayer(self.Queue[2])) then
				self:SafetyCheck()
				if #self.Queue < self.MaxPlayers then
					return
				end
			end

			self:UpdateInfoLabel(t)
			task.wait(1)
			t -= 1
		end

		if myId ~= self.CountdownId then
			return
		end

		self:SafetyCheck()
		if #self.Queue < self.MaxPlayers then
			return
		end

		local p1 = self.Queue[1]
		local p2 = self.Queue[2]
		if not (isValidPlayer(p1) and isValidPlayer(p2)) then
			self:SafetyCheck()
			if #self.Queue < self.MaxPlayers then
				return
			end
			p1 = self.Queue[1]
			p2 = self.Queue[2]
		end

		table.remove(self.Queue, 2)
		table.remove(self.Queue, 1)

		local psd1 = self.ServerManager.DataController:GetSessionData(p1)
		local psd2 = self.ServerManager.DataController:GetSessionData(p2)

		self.CountdownId += 1

		local targetCourt = court or self._Court
		if not targetCourt then
			error("No court specified for match creation!")
		end

		psd1.CurrentQueue = nil
		psd2.CurrentQueue = nil

		-- lock the queue until the match returns
		self.MatchInProgress = true
		self:UpdateInfoLabel()

		-- Match returns when finished, so we know it’s done here
		local match = Match.new(p1, p2, targetCourt, "Fast4", self.ServerManager)
		if match then
			psd1.CurrentMatch = match
			psd2.CurrentMatch = match
			match:Start() -- will block until match done
		else
			warn("Failed to create match!")
		end

		-- once Start() returns, unlock and refresh
		self.MatchInProgress = false
		self:Clear()
		self:UpdateInfoLabel()
	end)
end

function Queue:Clear()
	self.Queue = {}
	self.CountdownId += 1
	self:UpdateInfoLabel()
end

function Queue:Destroy()
	self:Clear()
	table.clear(self)
end

function Queue:SetInfoLabel(label: TextLabel)
	self.InfoLabel = label
	self:UpdateInfoLabel()
end

return Queue
