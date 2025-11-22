-- Set.lua
-- Param-driven tennis set logic.
-- Expects Match to pass in a uniform Params table (name, gamesToWinSet, winByGames, tiebreakAt, tiebreakPointsToWin, winByPointsTiebreak, useAdvantage, etc.)

local Game = require(script.Parent.Game)
local TiebreakGame = require(script.Parent.TiebreakGame)

export type Params = {
	name: string,
	description: string,
	setsToWin: number,
	totalSets: number,
	gamesToWinSet: number,
	winByGames: number,
	tiebreakAt: number,
	tiebreakPointsToWin: number,
	winByPointsTiebreak: number,
	useAdvantage: boolean,
	expectedDurationMinutes: number,
}

local Set = {}
Set.__index = Set

-- Players are Player objects; firstServer is a Player; params is the MatchTypes profile; match is the parent Match object
function Set.new(player1: Player, player2: Player, firstServer: Player, params: Params, match: any)
	local self = setmetatable({}, Set)

	self.Player1 = player1
	self.Player2 = player2
	self.Params = params
	self.Match = match
	self.ServerManager = match.ServerManager

	-- Track game count within this set (displayed as X–Y).
	self.Score = { [1] = 0, [2] = 0 }

	-- Serving order: store as indices 1 or 2
	if firstServer == player1 then
		self.nextServerIndex = 1
	else
		self.nextServerIndex = 2
	end

	return self
end

-- Utility: index <-> player
function Set:getPlayerByIndex(idx: number): Player
	return (idx == 1) and self.Player1 or self.Player2
end

function Set:getIndexForPlayer(player: Player): number
	return (player == self.Player1) and 1 or 2
end

-- === Game/Tiebreak glue ===

-- Start a single NORMAL game; return winner index (1 or 2)
function Set:startNormalGame(serverIndex: number): number
	-- Game.new(player1, player2, ServerIndex:number, MatchParams, Set)
	local game = Game.new(self.Player1, self.Player2, serverIndex, self.Params, self)
	local winnerIndex: number, _loser, _score = game:Start()
	return winnerIndex
end

-- Start a TIEBREAK; return winner index and raw tiebreak point score {p1Points, p2Points}
function Set:startTiebreak(serverIndex: number): (number, {number})
	-- TiebreakGame.new(player1, player2, ServerIndex:number, MatchParams, Set)
	local tb = TiebreakGame.new(self.Player1, self.Player2, serverIndex, self.Params, self)
	local winnerIndex: number, _loser, tbScore: {number} = tb:Start()
	return winnerIndex, tbScore
end

-- Alternate server for the next *normal* game.
function Set:rotateServer()
	self.nextServerIndex = (self.nextServerIndex == 1) and 2 or 1
end

-- === Set win conditions ===

-- Check if set is won in normal (non-tiebreak) flow
function Set:isSetWon(): number?
	local gToWin = self.Params.gamesToWinSet
	local leadNeeded = self.Params.winByGames
	local p1, p2 = self.Score[1], self.Score[2]

	if gToWin <= 0 then
		return nil -- handled elsewhere (tiebreak-only sets)
	end

	-- Someone reached threshold AND leads by required margin
	if p1 >= gToWin or p2 >= gToWin then
		local lead = math.abs(p1 - p2)
		if lead >= leadNeeded then
			return (p1 > p2) and 1 or 2
		end
	end

	return nil
end

-- Determine if we should trigger a tiebreak for a standard set.
function Set:shouldTiebreak(): boolean
	local tbAt = self.Params.tiebreakAt
	if tbAt <= 0 then
		return false
	end
	return (self.Score[1] == tbAt and self.Score[2] == tbAt)
end

-- === Public: play the set according to Params ===
function Set:Start(): (number, number, {number})
	local p = self.Params

	-- Mode A: Tiebreak-only set (gamesToWinSet == 0)
	if p.gamesToWinSet == 0 then
		-- Single tiebreak decides the "set". Server for the tiebreak is whoever is up next.
		local tbWinner, tbScore = self:startTiebreak(self.nextServerIndex)
		-- For display, set score reflects tiebreak points (e.g., 10–7, 21–19).
		self.Score[1], self.Score[2] = tbScore[1], tbScore[2]
		local loser = (tbWinner == 1) and 2 or 1
		return tbWinner, loser, self.Score
	end

	-- Mode B: Normal set with optional tiebreak at X–X
	while true do
		-- If we’re exactly at the trigger (e.g., 6–6 with tiebreakAt==6), play tiebreak to decide set 7–6.
		if self:shouldTiebreak() then
			local tbWinner, _tbScore = self:startTiebreak(self.nextServerIndex)

			-- Winner gets the set  (tbAt + 1) – (tbAt)
			local tbAt = p.tiebreakAt
			if tbWinner == 1 then
				self.Score[1] = tbAt + 1
				self.Score[2] = tbAt
			else
				self.Score[1] = tbAt
				self.Score[2] = tbAt + 1
			end

			print(string.format("Tiebreak set finished: %d–%d", self.Score[1], self.Score[2]))

			local loser = (tbWinner == 1) and 2 or 1
			return tbWinner, loser, self.Score
		end

		-- Otherwise, play a normal game.
		local gameWinner = self:startNormalGame(self.nextServerIndex)
		self.Score[gameWinner] += 1

		-- Print score after each game
		print(string.format("Set score: %d–%d", self.Score[1], self.Score[2]))

		-- Alternate server for next game
		self:rotateServer()

		-- Check normal set win (win-by condition)
		local setWinner = self:isSetWon()
		if setWinner then
			print(string.format("Set finished: %d–%d", self.Score[1], self.Score[2]))
			local loser = (setWinner == 1) and 2 or 1
			return setWinner, loser, self.Score
		end

		-- No winner yet; loop continues.
	end
end

return Set
