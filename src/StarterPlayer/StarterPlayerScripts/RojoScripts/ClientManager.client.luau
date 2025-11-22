-- ClientManager.luau
-- Root client controller. Handles client setup, and initializes other client modules.

local client = script.Parent

local DEBUG = true -- Set to false in production

repeat
	local success = pcall(function()
		-- StarterGui:SetCore("ResetButtonCallback", false)
	end)
	task.wait(0.1)
until success

local Controllers = client.controllers

local function RequireController(ControllerName)
	if Controllers:FindFirstChild(ControllerName) then
		if Controllers[ControllerName]:IsA("ModuleScript") then
			return require(Controllers[ControllerName])
		elseif Controllers[ControllerName][ControllerName]:IsA("ModuleScript") then
			return require(Controllers[ControllerName][ControllerName])
		end
		error("Invalid controller format: " .. ControllerName)
	else
		error("No such controller: " .. ControllerName)
	end
end

local RemoteController = RequireController("RemoteController")
local MatchController = RequireController("MatchController")
local ClientPadListener = RequireController("ClientPadListener")

local ClientManager = {}
ClientManager.__index = ClientManager

function ClientManager:Log(...)
	if self.Debug then
		print(...)
	end
end

function ClientManager.new()
	local self = setmetatable({}, ClientManager)

	self.Debug = DEBUG
	self:Log("ClientManager initializing")

	self.IsStudio = game:GetService("RunService"):IsStudio()
	self.ClientModeString = "PRODUCTION"
	self.JobId = nil
	self.Version = game.PlaceVersion

	self:SetIsStudio()

	self.RemoteController = RemoteController.new(self)
	self.MatchController = MatchController.new(self)
	self.ClientPadListener = ClientPadListener.new(self)

	return self
end

function ClientManager:SetIsStudio()
	if self.IsStudio then
		self.JobId = "STUDIO"
	else
		self.JobId = game.JobId
	end

	if self.IsStudio then
		self.ClientModeString = "STUDIO"
	end

	self:Log("ClientManager created in " .. self.ClientModeString .. " mode!")
end

-- Create an instance of ClientManager
local _ClientManagerInstance = ClientManager.new()
