local Queue = require(script.Parent.Parent.classes.Singles.Queue)
local Court = require(script.Parent.Parent.classes.Singles.Court)

local QueueController = {}
QueueController.__index = QueueController

function QueueController.new(ServerManager)
	local self = setmetatable({}, QueueController)
	self.ServerManager = ServerManager
	self.RemoteController = ServerManager.RemoteController
	self.DataController = ServerManager.DataController

	print("INIT QUEUECONTROLLER")

	local Court1 = Court.new(workspace.Courts.Singles.Court1)
	local QueueCourt1 = Queue.new(Court1, ServerManager)

	local singles = workspace.QueueStuff.Singles
	local _doubles = workspace.QueueStuff.Doubles

	local court1Label = singles.BBP.BillboardGui.TextLabel
	QueueCourt1:SetInfoLabel(court1Label)

	local padMap = {
		[1] = {
			Queue = QueueCourt1,
			Part = singles:WaitForChild("RegionPart")
		}
	}
	
	-- Now lets create listeners & the remotes we need
	local JoinQueue = self.RemoteController:AddOrGetEvent("JoinQueue")
	local LeaveQueue = self.RemoteController:AddOrGetEvent("LeaveQueue")

	local jsound = game.SoundService.JoinQueue
	local lsound = game.SoundService.LeaveQueue

	JoinQueue.OnServerEvent:Connect(function(plr, pad)
		print("PLR: ", plr, " PAD: ", pad)
		if padMap[pad] then
			local success = padMap[pad].Queue:AddPlayer(plr)
			if success then
				task.spawn(function()
					local jj = jsound:Clone()
					jj.Parent = padMap[pad].Part
					jj:Play()
					game:GetService("Debris"):AddItem(jj, 2)
				end)
			end
		end
	end)

	LeaveQueue.OnServerEvent:Connect(function(plr, pad)
		print("PLR: ", plr, " PAD: ", pad)
		if padMap[pad] then
			local success = padMap[pad].Queue:RemovePlayer(plr)
			if success then
					task.spawn(function()
					local ll = lsound:Clone()
					ll.Parent = padMap[pad].Part
					ll:Play()
					game:GetService("Debris"):AddItem(ll, 2)
				end)
			end
		end
	end)

	return self
end

return QueueController
