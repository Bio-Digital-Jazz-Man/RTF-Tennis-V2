local MatchController = {}
MatchController.__index = MatchController

function MatchController.new(ClientManager)
    local self = setmetatable({}, MatchController)

    self.ClientManager = ClientManager
    self.RemoteController = ClientManager.RemoteController
    self.InMatch = false
    self:SetupListeners()

    return self
end

function MatchController:SetupListeners()
    local EnterMatch = self.RemoteController:GetEvent("EnterMatch")
    EnterMatch.OnClientEvent:Connect(function()
        if not self.InMatch then
            self.InMatch = true
            print("GOT SIGNAL THAT ENTERED MATCH")
        else
            warn("Already in a match!")
        end
    end)
end

return MatchController