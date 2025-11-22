-- Server relay for racket sounds (Swing / Impact), excluding the originator.
-- Now forwards a power multiplier so clients match loudness.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RacketSoundEvent = ReplicatedStorage:WaitForChild("TennisEvents"):WaitForChild("RacketSoundEvent") :: RemoteEvent

-- Optional simple rate limit to avoid spam
local lastFire: { [Player]: number } = {}
local MIN_INTERVAL = 1/30 -- ~33ms per player

RacketSoundEvent.OnServerEvent:Connect(function(player: Player, soundType: string, toolName: string?, handleCFrame: CFrame?, powerMult: number?)
	-- Basic sanity checks
	if typeof(soundType) ~= "string" then return end
	if soundType ~= "Swing" and soundType ~= "Impact" then return end

	-- Rate-limit per player
	local now = os.clock()
	local prev = lastFire[player]
	if prev and (now - prev) < MIN_INTERVAL then return end
	lastFire[player] = now

	-- Clamp/normalize power multiplier (default 1.0 if missing)
	local pm: number = 1.0
	if typeof(powerMult) == "number" then
		pm = math.clamp(powerMult, 0.0, 10.0) -- generous clamp
	end

	-- Relay to everyone (clients will drop if they're the sender)
	-- Pass along: sender Player, soundType, toolName, handleCFrame, powerMult
	RacketSoundEvent:FireAllClients(player, soundType, toolName, handleCFrame, pm)
end)
