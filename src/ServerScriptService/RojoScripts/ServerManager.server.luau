-- ServerManager.luau
-- Root server controller. Handles server setup and shutdown, and initializes other modules.

local server = script.Parent

local DEBUG = true -- Set to false in production

local Controllers = server.controllers

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
local PlayersController = RequireController("PlayersController")
local DataController = RequireController("DataController")
local QueueController = RequireController("QueueController")

local ServerManager = {}
ServerManager.__index = ServerManager

function ServerManager:Log(...)
	if self.Debug then
		print(...)
	end
end

function ServerManager.new()
	local self = setmetatable({}, ServerManager)
	self.IsStudio = game:GetService("RunService"):IsStudio()
	self.ServerModeString = "PRODUCTION"
	self.JobId = nil
	self.Version = game.PlaceVersion
	self.Debug = DEBUG

	self:SetIsStudio()
	self:SetupControllers()
	self:SetupListeners()

	return self
end

function ServerManager:SetIsStudio()
	if self.IsStudio then
		self.JobId = "STUDIO"
	else
		self.JobId = game.JobId
	end

	if self.IsStudio then
		self.ServerModeString = "STUDIO"
	end

	self:Log("ServerManager created in " .. self.ServerModeString .. " mode!")
end

function ServerManager:SetupListeners()
	self.BindToCloseConnection = game:BindToClose(function()
		self:Cleanup()
	end)
end

function ServerManager:SetupControllers()
	self.RemoteController = RemoteController.new(self)
	self.DataController = DataController.new(self)
	self.PlayersController = PlayersController.new(self) -- Needs DataController
	self.QueueController = QueueController.new(self)
end

function ServerManager:Cleanup()
	self:Log("Bind to close executing!")

	-- Remove all the players
	for _, player in pairs(game.Players:GetChildren()) do
		player:Kick("This server has closed.")
	end
end

-- Create an instance of ServerManager
local _ServerManagerInstance = ServerManager.new()
