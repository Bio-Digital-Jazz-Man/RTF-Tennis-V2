--!nocheck
-- Minimal client: listens for server-sent baked trajectories and animates them.
-- Expects:
--   ReplicatedStorage.TennisEvents.BallTrajectory : RemoteEvent
--   ReplicatedStorage.Modules.BallAnimator        : Animator.Play(baked, opts)

local Players    = game:GetService("Players")
local Replicated = game:GetService("ReplicatedStorage")
local Workspace  = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

-- small load grace period so courts/walls are present
task.wait(5)

print("BALL CLIENT BALL CLIENT BALL CLIENT")

local Animator = require(Replicated:WaitForChild("Modules"):WaitForChild("BallAnimator"))
local LocalPlayer = Players.LocalPlayer

local ballById: { [string]: BasePart } = {}
local cleanupByPart: { [BasePart]: RBXScriptConnection } = setmetatable({}, { __mode = "k" })

local function disconnectCleanup(part: BasePart)
        local conn = cleanupByPart[part]
        if conn then
                conn:Disconnect()
                cleanupByPart[part] = nil
        end
end

local function registerBall(ballId: string?, part: BasePart?)
        if not ballId or ballId == "" or not part then
                return
        end

        local previous = ballById[ballId]
        if previous and previous ~= part then
                disconnectCleanup(previous)
        end

        ballById[ballId] = part
        part:SetAttribute("BallId", ballId)

        disconnectCleanup(part)
        cleanupByPart[part] = part.Destroying:Connect(function()
                if ballById[ballId] == part then
                        ballById[ballId] = nil
                end
                disconnectCleanup(part)
        end)
end

local function deriveBallId(baked: any): string
        local firstSample = baked and baked.samples and baked.samples[1]
        if typeof(firstSample) == "table" then
                local pos = firstSample.p
                local vel = firstSample.v
                if typeof(pos) == "Vector3" and typeof(vel) == "Vector3" then
                        local totalTime = typeof(baked.totalTime) == "number" and baked.totalTime or 0
                        return string.format(
                                "p%.3f,%.3f,%.3f|v%.3f,%.3f,%.3f|t%.3f",
                                pos.X,
                                pos.Y,
                                pos.Z,
                                vel.X,
                                vel.Y,
                                vel.Z,
                                totalTime
                        )
                end
        end

        return HttpService:GenerateGUID(false)
end

local function resolveBall(ballId: string?): BasePart?
        if not ballId then
                return nil
        end

        local part = ballById[ballId]
        if part and part.Parent then
                return part
        end

        if part then
                ballById[ballId] = nil
                disconnectCleanup(part)
        end

        return nil
end

local TennisEvents = Replicated:WaitForChild("TennisEvents")
local TrajEvent    = TennisEvents:WaitForChild("BallTrajectory") :: RemoteEvent

TrajEvent.OnClientEvent:Connect(function(payload: any)
        -- Accept { baked = <BakedPath>, ball = <BasePart?>, fromUserId=?, ... } or just baked itself
        local meta = typeof(payload) == "table" and payload or nil
        local baked = meta and (meta.baked or payload) or payload
        if not baked or not baked.samples or not baked.totalTime then
                warn("[ClientBallListener] Malformed baked trajectory payload.")
                return
        end

        local part = meta and (meta.ball or meta.part) or nil
        if part and not part:IsA("BasePart") then
                part = nil
        end

        local ballId = meta and meta.ballId or nil
        if typeof(ballId) ~= "string" or ballId == "" then
                ballId = nil
        end

        if part and not ballId then
                local attr = part:GetAttribute("BallId")
                if typeof(attr) == "string" and attr ~= "" then
                        ballId = attr
                end
        end

        if not part and ballId then
                part = resolveBall(ballId)
        end

        local lastHitUserId = meta and meta.lastHitUserId or nil
        if typeof(lastHitUserId) == "string" then
                lastHitUserId = tonumber(lastHitUserId)
        end
        if part and typeof(lastHitUserId) == "number" then
                pcall(function()
                        part:SetAttribute("LastHitUserId", lastHitUserId)
                end)
        end

        local fromUserId = meta and meta.fromUserId or nil
        local isLocalHit = (LocalPlayer ~= nil and typeof(fromUserId) == "number" and LocalPlayer.UserId == fromUserId)

        if isLocalHit then
                local resolved = part
                if not resolved and ballId then
                        resolved = resolveBall(ballId)
                end
                if ballId and resolved then
                        registerBall(ballId, resolved)
                end

                local relayMessage = meta and meta.relayMessage or nil
                if typeof(relayMessage) == "string" and #relayMessage > 0 then
                        --print(relayMessage)
                else
                        local serverDelay = meta and meta.serverDelay or nil
                        local serverBroadcastTime = meta and meta.serverBroadcastTime or nil
                        local clientSentTime = meta and meta.clientSentTime or nil
                        if typeof(serverDelay) == "number" and typeof(serverBroadcastTime) == "number" and typeof(clientSentTime) == "number" then
                                --[[print(string.format(
                                        "[ServerBallRelay] This is how long it took for the server to rebroadcast your hit: %.4fs (my_time=%.4f, your_time=%.4f)",
                                        serverDelay,
                                        serverBroadcastTime,
                                        clientSentTime
                                ))]]
                        end
                end
                return
        end

        if part then
                registerBall(ballId, part)
                Animator.PlayOnPart(part, baked, {
                        StartOffset   = 0,
                        DestroyOnStop = true,
                })
                return
        end

        -- Visual-only clone using the animator’s template & trail; auto-destroy on stop
        local handle = Animator.Play(baked, { Parent = Workspace, DestroyOnStop = true })
        if handle then
                local clonedPart = handle:GetPart()
                if clonedPart then
                        if not ballId then
                                ballId = deriveBallId(baked)
                        end
                        registerBall(ballId, clonedPart)
                end
        end
end)
