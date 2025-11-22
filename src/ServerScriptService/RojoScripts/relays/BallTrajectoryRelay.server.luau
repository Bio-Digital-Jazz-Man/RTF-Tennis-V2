--!nocheck
-- Server relay for client-baked ball trajectories.
-- Receives a baked path and ball reference from the hitting client, then
-- rebroadcasts that bake so every client (including the originator) can stay in sync.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TennisEvents = ReplicatedStorage:WaitForChild("TennisEvents")
local TrajEvent = TennisEvents:WaitForChild("BallTrajectory") :: RemoteEvent

local lastFire: { [Player]: number } = {}
local MIN_INTERVAL = 1 / 30 -- simple spam guard per player (~33ms)

local function isValidBaked(baked: any): boolean
        if typeof(baked) ~= "table" then
                return false
        end
        if typeof(baked.samples) ~= "table" then
                return false
        end
        if typeof(baked.totalTime) ~= "number" then
                return false
        end
        return true
end

TrajEvent.OnServerEvent:Connect(function(player: Player, payload: any)
        if typeof(payload) ~= "table" then
                return
        end

        local baked = payload.baked
        if not isValidBaked(baked) then
                return
        end

        local ball: BasePart? = payload.ball or payload.part
        if ball and not ball:IsA("BasePart") then
                ball = nil
        end

        local ballId = typeof(payload.ballId) == "string" and payload.ballId or nil
        if ballId == "" then
                ballId = nil
        end

        if ball then
                if not ball:IsDescendantOf(Workspace) then
                        return
                end
                if ball.CollisionGroup ~= "TennisBall" then
                        return
                end

                local existingId = ball:GetAttribute("BallId")
                if typeof(existingId) == "string" and existingId ~= "" then
                        if ballId and ballId ~= existingId then
                                ball:SetAttribute("BallId", ballId)
                        else
                                ballId = existingId
                        end
                elseif ballId then
                        ball:SetAttribute("BallId", ballId)
                end
        end

        if not ballId and ball then
                local inferredId = ball:GetAttribute("BallId")
                if typeof(inferredId) == "string" and inferredId ~= "" then
                        ballId = inferredId
                end
        end

        if not ball and not ballId then
                return
        end

        local lastHitUserId = payload.lastHitUserId
        if typeof(lastHitUserId) == "string" then
                lastHitUserId = tonumber(lastHitUserId)
        end
        if typeof(lastHitUserId) ~= "number" then
                lastHitUserId = player.UserId
        end

        if ball and lastHitUserId then
                pcall(function()
                        ball:SetAttribute("LastHitUserId", lastHitUserId)
                end)
        end

        local now = os.clock()
        local prev = lastFire[player]
        if prev and (now - prev) < MIN_INTERVAL then
                return
        end
        lastFire[player] = now

        local clientSentTime = typeof(payload.clientSentTime) == "number" and payload.clientSentTime or nil
        local serverBroadcastTime = Workspace:GetServerTimeNow()
        local serverDelay = clientSentTime and (serverBroadcastTime - clientSentTime) or nil

        local relayMessage: string? = nil
        if serverDelay then
                relayMessage = string.format(
                        "[ServerBallRelay] This is how long it took for the server to rebroadcast your hit: %.4fs (my_time=%.4f, your_time=%.4f)",
                        serverDelay,
                        serverBroadcastTime,
                        clientSentTime
                )
        end

        TrajEvent:FireAllClients({
                baked = baked,
                ball = ball,
                part = ball, -- legacy name for existing listeners
                ballId = ballId,
                fromUserId = player.UserId,
                clientSentTime = clientSentTime,
                serverBroadcastTime = serverBroadcastTime,
                serverDelay = serverDelay,
                relayMessage = relayMessage,
                lastHitUserId = lastHitUserId,
        })
end)
