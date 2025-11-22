local StarterGui = game:GetService("StarterGui")
local Chat = game:GetService("Chat")

local function setUpChatWindow()
	return {
		BubbleChatEnabled = true,
		ClassicChatEnabled = true
	}
end

Chat:RegisterChatCallback(Enum.ChatCallbackType.OnCreatingChatWindow, setUpChatWindow)

-- Hide player list
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)

-- Function to safely set core stuff (wait until available)
local function safeSetCore(coreName, value)
    local success = false
    repeat
        success = pcall(function()
            StarterGui:SetCore(coreName, value)
        end)
        if not success then
            task.wait(0.1)
        end
    until success
end

-- Disable reset button
safeSetCore("ResetButtonCallback", false)

