-- Game.lua
-- Normal (non-tiebreak) game logic driven entirely by Params.
-- Params fields used:
--   useAdvantage: boolean (true = deuce/adv, false = no-ad; deciding point at 40–40)

local Point = require(script.Parent.Point)

local Game = {}
Game.__index = Game

-- Server is a player index (1 or 2). MatchParams is the uniform params table. Set is the parent set.
function Game.new(player1: Player, player2: Player, Server: number, MatchParams, Set)
	local self = setmetatable({}, Game)

	self.Player1 = player1
	self.Player2 = player2
	self.Server = Server
	self.Set = Set
	self.Params = MatchParams
	self.ServerManager = Set.ServerManager

	return self
end

-- Internal pretty names for traditional scoring; for no-ad we still print these up to 40–40.
local pointNames = { [0] = "0", [1] = "15", [2] = "30", [3] = "40", [4] = "Adv" }

-- Determine if someone has won under advantage or no-ad rules
local function winnerAdv(p1: number, p2: number): number?
	-- Traditional: first to >=4 with a lead of 2
	if (p1 >= 4 or p2 >= 4) and math.abs(p1 - p2) >= 2 then
		return (p1 > p2) and 1 or 2
	end
	return nil
end

local function winnerNoAd(p1: number, p2: number): number?
	-- No-ad: first to 4 wins, even at 4–3
	if p1 >= 4 or p2 >= 4 then
		return (p1 > p2) and 1 or 2
	end
	return nil
end

function Game:Start()
	local useAdvantage: boolean = self.Params.useAdvantage
	local score = { [1] = 0, [2] = 0 }
	local winner: number? = nil
	local pointNumber = 0

	print("\nStarting Game\n")

	local function isWinner(): number?
		if useAdvantage then
			return winnerAdv(score[1], score[2])
		else
			return winnerNoAd(score[1], score[2])
		end
	end

	while not winner do
		pointNumber += 1

		-- Alternate serve sides (Deuce / Ad)
		local serveSide = (pointNumber % 2 == 1) and "Deuce" or "Ad"

		-- Play a point
		local point = Point.new(self.Player1, self.Player2, self.Server, self, serveSide, self.Params)
		local pointWinner = point:Start()

		score[pointWinner] += 1
		winner = isWinner()
	end

	local loser = (winner == 1) and 2 or 1

	-- Proper end-of-game labeler
	local function label(v: number, other: number, isWinner: boolean): string
		-- Handle extended deuce logic and convert final advantage to Game
		if v >= 3 and other >= 3 then
			if v == other then
				return "40"
			elseif v == other + 1 then
				-- At deuce + 1: only show Adv if not yet game-winning
				return isWinner and "Game" or "Adv"
			elseif v > other + 1 then
				return isWinner and "Game" or "40"
			else
				return "40"
			end
		else
			-- Normal pre-deuce progression
			return isWinner and v > other and "Game" or (pointNames[v] or "0")
		end
	end

	print(string.format(
		"Game complete. Player %d wins %s–%s",
		winner :: number,
		label(score[1], score[2], winner == 1),
		label(score[2], score[1], winner == 2)
	))

	return winner, loser, score
end

return Game
