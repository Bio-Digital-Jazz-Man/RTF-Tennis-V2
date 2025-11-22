-- Client listener for relayed racket sounds with power-scaled volume + pitch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RacketSoundEvent = ReplicatedStorage:WaitForChild("TennisEvents"):WaitForChild("RacketSoundEvent") :: RemoteEvent
local player = game.Players.LocalPlayer

-- 1x baselines (must match tool script)
local IMPACT_VOL_1X = 3.0
local SWING_VOL_1X  = 0.8

-- Map 0.5x → 0.95, 1.0x → 1.0, 2.0x → 1.05
local function multiplierToOctave(m: number): number
	if m <= 1.0 then
		local t = (m - 0.5) / 0.5 -- 0 → 0.5x, 1 → 1.0x
		return 0.95 + 0.05 * t
	else
		local t = (m - 1.0) / 1.0 -- 0 → 1.0x, 1 → 2.0x
		return 1.0 + 0.05 * t
	end
end

RacketSoundEvent.OnClientEvent:Connect(function(sender: Player, soundType: string, toolName: string?, handleCFrame: CFrame?, powerMult: number?)
	-- Don’t double-play for the instigator
	if sender == player then return end
	if soundType ~= "Swing" and soundType ~= "Impact" then return end

	local pm = (typeof(powerMult) == "number") and powerMult or 1.0

	-- Try to locate the *sender's* tool handle on this client
	local targetHandle: BasePart? = nil
	local char = sender.Character
	if char and char.Parent == workspace then
		local tname = toolName or "Tool"
		local senderTool = char:FindFirstChild(tname)
		if senderTool and senderTool:IsA("Tool") then
			local h = senderTool:FindFirstChild("Handle")
			if h and h:IsA("BasePart") then
				targetHandle = h
			end
		end
	end

	if targetHandle then
		local s = targetHandle:FindFirstChild(soundType)
		if s and s:IsA("Sound") then
			-- Volume scaling
			local base = (soundType == "Impact") and IMPACT_VOL_1X or SWING_VOL_1X
			s.Volume = base * pm

			if soundType == "Swing" then
                s.Volume = SWING_VOL_1X  -- JUST DONT DO IT FOR SWINGS FOR NOW
            end

			-- Pitch scaling
			local pitch = s:FindFirstChild("PitchShiftSoundEffect")
			if pitch then
				pitch.Octave = multiplierToOctave(pm)
			end

			--print(("PLAYING %s with volume %.2f, octave %.2f"):format(soundType, s.Volume, pitch and pitch.Octave or 1))
			pcall(function() s:Play() end)
			return
		end
	end
end)
