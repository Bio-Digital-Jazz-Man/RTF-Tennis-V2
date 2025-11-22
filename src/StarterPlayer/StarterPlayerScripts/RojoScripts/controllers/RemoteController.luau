-- RemoteController.luau
-- Sets up remotes in the specified directories

local RemoteController = {}
RemoteController.__index = RemoteController

local shared = game:GetService("ReplicatedStorage").Shared
local Remotes = shared.Remotes

local EventDirectory = Remotes.Events
local FunctionDirectory = Remotes.Functions

function RemoteController.new(ClientManager)
	local self = setmetatable({}, RemoteController)
	self.ClientManager = ClientManager

	return RemoteController
end

function RemoteController:GetEvent(EventName)
	EventDirectory:WaitForChild(EventName, 10)
	if not EventDirectory:FindFirstChild(EventName) then
		error("Could not get RemoteEvent " .. EventName)
	end
	return EventDirectory:FindFirstChild(EventName)
end

function RemoteController:GetFunction(FunctionName)
	FunctionDirectory:WaitForChild(FunctionName, 10)
	if not FunctionDirectory:FindFirstChild(FunctionName) then
		error("Could not get RemoteFunction " .. FunctionName)
	end
	return FunctionDirectory:FindFirstChild(FunctionName)
end

return RemoteController
