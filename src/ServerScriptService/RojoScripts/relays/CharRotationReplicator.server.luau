--!nocheck
-- ServerScriptService/CharRotationRelay.server.lua
-- Relays total yaw/pitch (radians) from a sender to all other clients.
-- Uses ReplicatedStorage.CharRotation (UnreliableRemoteEvent or RemoteEvent).
-- Security: sanity-clamps values and validates player/character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local event = (ReplicatedStorage:WaitForChild("MiscEvents"):WaitForChild("CharRotation") :: any) :: RemoteEvent

-- Caps must match client logic (defensive clamping)
local TOTAL_MAX_YAW_RAD = math.rad(100)
local TOTAL_MAX_PITCH_RAD = math.rad(90)

event.OnServerEvent:Connect(function(sender: Player, yawTotal: number, pitchTotal: number)
	-- Quick validation
	if typeof(yawTotal) ~= "number" or typeof(pitchTotal) ~= "number" then
		return
	end

	local character = sender.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end

	-- Clamp to expected limits
	local y = math.clamp(yawTotal, -TOTAL_MAX_YAW_RAD, TOTAL_MAX_YAW_RAD)
	local p = math.clamp(pitchTotal, -TOTAL_MAX_PITCH_RAD, TOTAL_MAX_PITCH_RAD)

	-- Relay to everyone (including sender is fine; clients ignore their own id),
	-- but we can save a few bytes by excluding the sender:
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= sender then
			event:FireClient(plr, sender.UserId, y, p)
		end
	end
end)
