-- Point.lua
-- Orchestrator for a single point.
-- This version *does not simulate* anything and *does not call* unknown functions.
-- It only prints TODOs and enforces the contract: return winner index (1 or 2).

local BallPhysics = require(game.ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("BallPhysics"))
local BallTrajectory = game.ReplicatedStorage:WaitForChild("TennisEvents"):WaitForChild("BallTrajectory")

local Point = {}
Point.__index = Point

export type MatchParams = {
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

function Point.new(player1: Player, player2: Player, Server: number, Game, Side: string, MatchParams: MatchParams)
	local self = setmetatable({}, Point)

	self.Player1 = player1
	self.Player2 = player2
	self.Server = Server           -- 1 or 2
	self.Game = Game               -- parent Game or TiebreakGame
	self.Params = MatchParams
	self.Side = Side               -- "Deuce" or "Ad"
	self.Court = Game.Set.Match.Court
	self.ServerManager = Game.ServerManager
	print(Game, self.ServerManager)
	self.RemoteController = self.ServerManager.RemoteController

	return self
end

-- Contract: MUST return 1 or 2 (winner index).
function Point:Start(): number
	local serverIndex = self.Server
	local _receiverIndex = (serverIndex == 1) and 2 or 1

	print(("\n[POINT] Start | Server=P%d | Side=%s | Mode=%s")
		:format(serverIndex, self.Side, self.Params.name))

	print(self.Court)
	print(self.Side)
	print(self.Server)

	local EnterMatch = self.RemoteController:AddOrGetEvent("EnterMatch")
	EnterMatch:FireClient(self.Player1)
	EnterMatch:FireClient(self.Player2)

	local ServePlayer = self.Server == 1 and self.Player1 or self.Player2
	local ReceivePlayer = (ServePlayer == self.Player1 and self.Player2) or self.Player1
	local ServeChar = ServePlayer.Character
	local ReceiveChar = ReceivePlayer.Character

	local function resetServeBoxes()
		for _, box in pairs({self.Court.ServeBox1R, self.Court.ServeBox1L, self.Court.ServeBox2R, self.Court.ServeBox2L}) do
			for i,v in pairs(box:GetChildren()) do
				if v:IsA("Part") then
					v.CanCollide = false
					v.Transparency = 1
				end
			end
		end
	end

	local function setServeBox(serveBox)
		for i,v in pairs(serveBox:GetChildren()) do
			if v:IsA("Part") then
				v.CanCollide = true
				v.Transparency = 0.9
			end
		end
	end

	resetServeBoxes()
	if self.Side == "Deuce" then
		setServeBox(self.Court.ServeBox1R)
		ServeChar:SetPrimaryPartCFrame(self.Court.ServeR1.CFrame)
		ReceiveChar:SetPrimaryPartCFrame(self.Court.ServeR2.CFrame)
	else
		setServeBox(self.Court.ServeBox1L)
		ServeChar:SetPrimaryPartCFrame(self.Court.ServeL1.CFrame)
		ReceiveChar:SetPrimaryPartCFrame(self.Court.ServeL2.CFrame)
	end

	-- Spawn the ball 1 stud forward and 1.5 studs to the right of the server's HRP
	local hrp = ServeChar:WaitForChild("HumanoidRootPart")
	local forwardOffset = hrp.CFrame.LookVector * 2.5
	local rightOffset = hrp.CFrame.RightVector * 3
	local spawnPosition = hrp.Position + forwardOffset + rightOffset

	-- Bake the ball trajectory from the offset spawn position
	local bakedPath = BallPhysics.Bake(spawnPosition, Vector3.new(0, 32, 0), nil)
	BallTrajectory:FireAllClients(bakedPath)


	-- ================================
	-- TODO: Position players for the point (serve side, stance, cameras, HUD)
	-- e.g., place server at baseline on %s side; place receiver opposite.
	-- ================================
	print("[TODO] Position players for serve & receive based on Side and court layout")

	-- ================================
	-- TODO: Begin 'serve-and-rally' flow (one unified action).
	-- IMPORTANT: Your game should drive the entire point here (serve + rally)
	-- and determine the winner WHEN THE BALL IS DEAD.
	-- ================================
	print("[TODO] Run serve-and-rally (single unified flow) until point ends")

	-- ================================
	-- TODO: Decide winner index (1 or 2) when the rally ends.
	-- - If you support lets/faults:
	--     * Handle let: redo serve within your own system.
	--     * Handle double fault: award point to receiver (", receiverIndex, ").
	-- - Otherwise, once ball is out/untouchable/double-bounce/net etc.,
	--   set 'winnerIndex' accordingly.
	-- ================================
	print("[TODO] Determine winnerIndex = 1 or 2 based on actual ball outcome")

	-- Placeholder to force you to wire the real result in.
	local winnerIndex: number? = nil
	-- winnerIndex = 1 -- <- set this when your point logic resolves
	-- winnerIndex = 2 -- <- or this

	if winnerIndex ~= 1 and winnerIndex ~= 2 then
		error("[POINT] winnerIndex not set. Implement your serve-and-rally logic and assign 1 or 2.")
	end

	local loserIndex = (winnerIndex == 1) and 2 or 1
	print(("[POINT] Complete | Winner=P%d, Loser=P%d"):format(winnerIndex :: number, loserIndex))

	return winnerIndex :: number
end

return Point
