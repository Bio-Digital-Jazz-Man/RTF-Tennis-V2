-- RemoteController.luau
-- Sets up remotes in the specified directories, ensuring folder structure exists

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Utility to get or create a Folder under a parent
local function getOrCreateFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
	end
	return folder
end

-- Ensure hierarchical folder structure
local shared = getOrCreateFolder(ReplicatedStorage, "Shared")
local Remotes = getOrCreateFolder(shared, "Remotes")
local EventDirectory = getOrCreateFolder(Remotes, "Events")
local FunctionDirectory = getOrCreateFolder(Remotes, "Functions")
local Bindables = getOrCreateFolder(Remotes, "Bindables")
local BindableEventDirectory = getOrCreateFolder(Bindables, "Events")
local BindableFunctionDirectory = getOrCreateFolder(Bindables, "Functions")

local RemoteController = {}
RemoteController.__index = RemoteController

function RemoteController.new(ServerManager)
	local self = setmetatable({}, RemoteController)
	self.ServerManager = ServerManager
	self.Remotes = {
		Events = {},
		Functions = {},
		BindableEvents = {},
		BindableFunctions = {},
	}
	self:Init()
	return self
end

function RemoteController:AddEvent(EventName)
	if self.Remotes.Events[EventName] then
		error("RemoteEvent " .. EventName .. " is already defined!")
	end
	local re = Instance.new("RemoteEvent")
	re.Name = EventName
	re.Parent = EventDirectory
	self.Remotes.Events[EventName] = re
end

function RemoteController:AddFunction(FunctionName)
	if self.Remotes.Functions[FunctionName] then
		error("RemoteFunction " .. FunctionName .. " is already defined!")
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = FunctionName
	rf.Parent = FunctionDirectory
	self.Remotes.Functions[FunctionName] = rf
end

function RemoteController:AddOrGetEvent(EventName)
	if not self.Remotes.Events[EventName] then
		local re = Instance.new("RemoteEvent")
		re.Name = EventName
		re.Parent = EventDirectory
		self.Remotes.Events[EventName] = re
	end
	return self.Remotes.Events[EventName]
end

function RemoteController:AddOrGetBindableEvent(BindableEventName)
	if not self.Remotes.BindableEvents[BindableEventName] then
		local be = Instance.new("BindableEvent")
		be.Name = BindableEventName
		be.Parent = BindableEventDirectory
		self.Remotes.BindableEvents[BindableEventName] = be
	end
	return self.Remotes.BindableEvents[BindableEventName]
end

function RemoteController:AddOrGetBindableFunction(BindableFunctionName)
	if not self.Remotes.BindableFunctions[BindableFunctionName] then
		local bf = Instance.new("BindableFunction")
		bf.Name = BindableFunctionName
		bf.Parent = BindableFunctionDirectory
		self.Remotes.BindableFunctions[BindableFunctionName] = bf
	end
	return self.Remotes.BindableFunctions[BindableFunctionName]
end

function RemoteController:AddOrGetFunction(FunctionName)
	if not self.Remotes.Functions[FunctionName] then
		local rf = Instance.new("RemoteFunction")
		rf.Name = FunctionName
		rf.Parent = FunctionDirectory
		self.Remotes.Functions[FunctionName] = rf
	end
	return self.Remotes.Functions[FunctionName]
end

function RemoteController:GetEvent(EventName)
	return self.Remotes.Events[EventName]
end

function RemoteController:GetFunction(FunctionName)
	return self.Remotes.Functions[FunctionName]
end

function RemoteController:Init()
	-- Setup remotes that need init here
	self:AddOrGetEvent("EnterMatch")
end

return RemoteController
