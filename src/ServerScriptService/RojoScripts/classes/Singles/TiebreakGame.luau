-- TiebreakGame.lua
-- Param-driven tiebreak logic.
-- Params fields used:
--   tiebreakPointsToWin: number (e.g., 7 for standard, 10/15/21 for "super")
--   winByPointsTiebreak: number (usually 2)
-- Notes:
--   - Serve pattern: first point by the incoming server, then switch every two points.
--   - Side (Deuce/Ad) alternates each point for ball toss orientation in your Point module.
--   - If you implement end changes, they typically occur every 6 points (not required here).

local Point = require(script.Parent.Point)

local TiebreakGame = {}
TiebreakGame.__index = TiebreakGame

-- Server is a player index (1 or 2). MatchParams is the uniform params table. Set is the parent set.
function TiebreakGame.new(player1: Player, player2: Player, Server: number, MatchParams, Set)
	local self = setmetatable({}, TiebreakGame)

	self.Player1 = player1
	self.Player2 = player2
	self.Server = Server
	self.Set = Set
    warn("self.Params being set to ", MatchParams)
	self.Params = MatchParams
	self.ServerManager = Set.ServerManager

	return self
end

local function hasTbWinner(p1: number, p2: number, pointsToWin: number, winBy: number): number?
	if (p1 >= pointsToWin or p2 >= pointsToWin) and math.abs(p1 - p2) >= winBy then
		return (p1 > p2) and 1 or 2
	end
	return nil
end

function TiebreakGame:Start()
	local score = { [1] = 0, [2] = 0 }
	local winner: number? = nil
	local loser: number? = nil

	local tbTarget = self.Params.tiebreakPointsToWin
	local tbWinBy = self.Params.winByPointsTiebreak

	print("\nStarting Tiebreak Game\n")

	local pointCount = 0
	local currentServer = self.Server

	local function printScore()
		print(string.format("Tiebreak score: %d–%d", score[1], score[2]))
	end

	while not winner do
		pointCount += 1

		-- Deuce/Ad side alternates every point
		local serveSide = (pointCount % 2 == 1) and "Deuce" or "Ad"

		-- Server switching:
		--  - First point served by incoming server
		--  - Then switch every two points: 2–3, 4–5, 6–7, ...
		if pointCount > 1 and ((pointCount - 1) % 2 == 0) then
			currentServer = (currentServer == 1) and 2 or 1
		end

		local point = Point.new(self.Player1, self.Player2, currentServer, self, serveSide, self.Params)
		local pointWinner = point:Start()

		score[pointWinner] += 1
		print(string.format("Player %d wins tiebreak point %d (%s side)", pointWinner, pointCount, serveSide))
		printScore()

		winner = hasTbWinner(score[1], score[2], tbTarget, tbWinBy)
	end

	loser = (winner == 1) and 2 or 1
	print(string.format("Tiebreak complete. Player %d wins %d–%d", winner :: number, score[1], score[2]))

	return winner, loser, score
end

return TiebreakGame
