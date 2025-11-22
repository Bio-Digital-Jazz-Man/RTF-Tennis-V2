local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ClientPadListener = {}
ClientPadListener.__index = ClientPadListener

function ClientPadListener.new(ClientManager)
	local self = setmetatable({}, ClientPadListener)
	self.ClientManager = ClientManager

	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	local humanoidRootPart = character:WaitForChild("HumanoidRootPart")

	local JoinQueue = self.ClientManager.RemoteController:GetEvent("JoinQueue")
	local LeaveQueue = self.ClientManager.RemoteController:GetEvent("LeaveQueue")

	-- MANUALLY define which RegionParts map to which queue numbers
	local QueueMap = {
		[workspace.QueueStuff.Singles:WaitForChild("RegionPart")] = 1,
	}

	-- track which regions we're currently inside
	local activeStates = {}
	for regionPart in pairs(QueueMap) do
		activeStates[regionPart] = false
	end

	local function isInsideRegion(regionPart)
		if not character or not humanoidRootPart or not regionPart then
			return false
		end

		local charPos = humanoidRootPart.Position
		local partPos = regionPart.Position
		local halfSize = regionPart.Size / 2

		return (
			math.abs(charPos.X - partPos.X) <= halfSize.X and
			math.abs(charPos.Y - partPos.Y) <= halfSize.Y and
			math.abs(charPos.Z - partPos.Z) <= halfSize.Z
		)
	end

	-- unified logic loop — handles all pads efficiently
	RunService.Heartbeat:Connect(function()
		for regionPart, queueNumber in pairs(QueueMap) do
			local insideNow = isInsideRegion(regionPart)
			local wasInside = activeStates[regionPart]

			if insideNow and not wasInside then
				activeStates[regionPart] = true
				print(`ENTERED queue {queueNumber}`)
				JoinQueue:FireServer(queueNumber)

			elseif not insideNow and wasInside then
				activeStates[regionPart] = false
				print(`LEFT queue {queueNumber}`)
				LeaveQueue:FireServer(queueNumber)
			end
		end
	end)

	return self
end

return ClientPadListener
