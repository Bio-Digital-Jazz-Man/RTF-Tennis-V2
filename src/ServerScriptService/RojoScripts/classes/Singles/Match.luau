local Types = require(script.Parent.Types)
local Set = require(script.Parent.Set)

local Match = {}
Match.__index = Match

-- === MATCH DEFINITIONS (UNIFORM PARAMS) ===
local MatchTypes = {
	Professional = {
		name = "Professional",
		description = "Authentic full match with traditional scoring and tiebreaks at 6–6.",
		setsToWin = 2,
		totalSets = 3,
		gamesToWinSet = 6,
		winByGames = 2,
		tiebreakAt = 6,
		tiebreakPointsToWin = 7,
		winByPointsTiebreak = 2,
		useAdvantage = true,
		expectedDurationMinutes = 120,
	},

	Fast4 = {
		name = "Fast4",
		description = "Quick format: first to 4 games, no-ad scoring, tiebreak at 3–3.",
		setsToWin = 2,
		totalSets = 3,
		gamesToWinSet = 4,
		winByGames = 1,
		tiebreakAt = 3,
		tiebreakPointsToWin = 7,
		winByPointsTiebreak = 2,
		useAdvantage = false,
		expectedDurationMinutes = 25,
	},

	SingleSet = { -- "Club Classic"
		name = "Single Set",
		description = "One-set match for casual play or tournaments.",
		setsToWin = 1,
		totalSets = 1,
		gamesToWinSet = 6,
		winByGames = 2,
		tiebreakAt = 6,
		tiebreakPointsToWin = 7,
		winByPointsTiebreak = 2,
		useAdvantage = true,
		expectedDurationMinutes = 20,
	},

	SuperTiebreak = {
		name = "Super Tiebreak",
		description = "Single extended tiebreak—fast, high-pressure format.",
		setsToWin = 1,
		totalSets = 1,
		gamesToWinSet = 0,
		winByGames = 0,
		tiebreakAt = 0,
		tiebreakPointsToWin = 15,
		winByPointsTiebreak = 2,
		useAdvantage = false,
		expectedDurationMinutes = 10,
	},

	Arcade = {
		name = "Arcade",
		description = "Continuous scoring mode—pure rally flow, no downtime.",
		setsToWin = 1,
		totalSets = 1,
		gamesToWinSet = 0,
		winByGames = 0,
		tiebreakAt = 0,
		tiebreakPointsToWin = 21,
		winByPointsTiebreak = 2,
		useAdvantage = false,
		expectedDurationMinutes = 10,
	},
}

-- === MATCH CONSTRUCTOR ===
function Match.new(player1: Player, player2: Player, court: Types.Court, MatchType: string, ServerManager)
	if not MatchType then
		error("No MatchType provided!")
	end

	local Params = MatchTypes[MatchType]
	if not Params then
		error(("Invalid MatchType '%s'"):format(tostring(MatchType)))
	end

	local self = setmetatable({}, Match)

	self.Player1 = player1
	self.Player2 = player2
	self.Court = court
	self.ServerManager = ServerManager
	self.Params = Params

	if court.Match == nil then
		court:AssignMatch(self)
	end

	local DC = ServerManager.DataController
	DC:ClearPlayerQueue(player1)
	DC:ClearPlayerQueue(player2)
	DC:SetPlayerMatch(player1, self)
	DC:SetPlayerMatch(player2, self)

	print(string.format("Match created: %s vs %s [%s]", player1.Name, player2.Name, Params.name))

	self.Player1Score = 0
	self.Player2Score = 0
	self.FirstPlayer = (math.random() < 0.5 and player1) or player2
	self.SecondPlayer = (self.FirstPlayer == player1 and player2) or player1

	return self
end

-- === MATCH FLOW ===
function Match:Start()
	local p = self.Params
	local score = { [1] = 0, [2] = 0 } -- sets won per player
	local winner = nil
	local loser = nil

	print(("\nStarting %s match (%s)\n"):format(p.name, p.description))

	-- Core helper: check if match is won based on params
	local function isMatchWinner(score)
		local p1, p2 = score[1], score[2]
		if p1 >= p.setsToWin or p2 >= p.setsToWin then
			return (p1 > p2) and 1 or 2
		end
		return nil
	end

	-- Run a single set using Set module and match params
	local function runSet(firstServerIndex: number)
		local firstServer = (firstServerIndex == 1) and self.Player1 or self.Player2
		local ThisSet = Set.new(self.Player1, self.Player2, firstServer, self.Params, self)
		local setWinner, setLoser, setScore = ThisSet:Start()
		score[setWinner] += 1
		print(string.format("Set %d–%d | Match score: %d–%d", setScore[1], setScore[2], score[1], score[2]))
		return setWinner, setLoser
	end

	-- Determine who serves first and alternate
	local nextFirstServer = 1

	while not winner do
		local matchWinner = isMatchWinner(score)
		if matchWinner then
			winner = matchWinner
			break
		end

		local _setWinner, _setLoser = runSet(nextFirstServer)
		nextFirstServer = (nextFirstServer == 1) and 2 or 1

		if isMatchWinner(score) then
			winner = isMatchWinner(score)
			break
		end
	end

	loser = (winner == 1) and 2 or 1
	print(string.format("MATCH COMPLETE! Player %d wins %d–%d", winner, score[1], score[2]))

	return winner, loser, score
end

-- === PLAYER LEAVE CLEANUP ===
function Match:RemovePlayer(player: Player)
	local otherPlayer
	if player == self.Player1 then
		otherPlayer = self.Player2
	elseif player == self.Player2 then
		otherPlayer = self.Player1
	end

	print(("Player %s left the match"):format(player.Name))

	local DC = self.ServerManager.DataController
	if otherPlayer then
		DC:RecomputeELOs(otherPlayer, player)
	end

	if self.Court then
		self.Court:ClearMatch()
	end

	if otherPlayer then
		DC:ClearPlayerMatch(otherPlayer)
	end

	self.Player1 = nil
	self.Player2 = nil
	self.Court = nil
end

return Match
