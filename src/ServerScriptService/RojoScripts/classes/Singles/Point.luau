-- Point.lua
-- Server-authoritative orchestrator for a single point.

local Workspace = game:GetService("Workspace")

local BallPhysics = require(game.ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("BallPhysics"))
local BallTrajectory = game.ReplicatedStorage:WaitForChild("TennisEvents"):WaitForChild("BallTrajectory")

local Point = {}
Point.__index = Point

export type MatchParams = {
    name: string,
    description: string,
    setsToWin: number,
    totalSets: number,
    gamesToWinSet: number,
    winByGames: number,
    tiebreakAt: number,
    tiebreakPointsToWin: number,
    winByPointsTiebreak: number,
    useAdvantage: boolean,
    expectedDurationMinutes: number,
}

local function now(): number
    return Workspace:GetServerTimeNow()
end

local function formatVector(v: Vector3?): string
    if not v then return "<nil>" end
    return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

local function getFirstSample(baked)
    return baked and baked.samples and baked.samples[1] or nil
end

local function nextImpactOfKind(baked, kind: string?, afterT: number?)
    if not baked or typeof(baked.impacts) ~= "table" then
        return nil
    end

    for _, impact in ipairs(baked.impacts) do
        if (not kind or impact.kind == kind) and (not afterT or impact.t > afterT) then
            return impact
        end
    end

    return nil
end

local function debugImpacts(prefix: string, baked)
    print(prefix .. " | Impact list start")
    if not baked or not baked.impacts then
        print(prefix .. " | <no impacts>")
        return
    end
    for i, impact in ipairs(baked.impacts) do
        print(prefix .. string.format(" | #%d kind=%s t=%.3f pos=%s", i, tostring(impact.kind), impact.t, formatVector(impact.pos)))
    end
    print(prefix .. " | Impact list end")
end

function Point.new(player1: Player, player2: Player, Server: number, Game, Side: string, MatchParams: MatchParams)
    local self = setmetatable({}, Point)

    self.Player1 = player1
    self.Player2 = player2
    self.Server = Server           -- 1 or 2
    self.Game = Game               -- parent Game or TiebreakGame
    self.Params = MatchParams
    self.Side = Side               -- "Deuce" or "Ad"
    self.Court = Game.Set.Match.Court
    self.ServerManager = Game.ServerManager
    self.RemoteController = self.ServerManager.RemoteController

    return self
end

-- Serve fault visualization helpers ----------------------------------------
-- ADDED ---------------------------------------------------------------------
local function setBoxRed(box)
    for _, v in pairs(box:GetChildren()) do
        if v:IsA("Part") then
            v.CanCollide = true
            v.Transparency = 0.1
            v.Color = Color3.new(1, 0, 0)
        end
    end
end

local function clearBox(box)
    for _, v in pairs(box:GetChildren()) do
        if v:IsA("Part") then
            v.CanCollide = false
            v.Transparency = 1
        end
    end
end
-- END ADDED -----------------------------------------------------------------

-- Validate a reported hit
function Point:_validateHit(eventData, expectedPlayer: Player, windowStart: number, windowEnd: number, predictedBounceAbs: number, currentBaked, currentStartTime: number)
    local player = eventData.player
    local payload = eventData.payload
    local serverTime = eventData.serverTime

    local claimedTime = (typeof(payload.clientSentTime) == "number" and payload.clientSentTime) or serverTime
    local baked = payload.baked

    if player ~= expectedPlayer then
        return { ok = false, reason = string.format("Hit from %s but waiting for %s", player.Name, expectedPlayer.Name) }
    end

    if not baked or typeof(baked) ~= "table" or typeof(baked.samples) ~= "table" then
        return { ok = false, reason = "Malformed baked payload" }
    end

    if claimedTime > windowEnd then
        return { ok = false, reason = string.format("Hit reported after windowEnd (%.3f > %.3f)", claimedTime, windowEnd) }
    end

    if claimedTime > (predictedBounceAbs + 1) then
        return { ok = false, reason = "Hit exceeds allowed post-bounce buffer" }
    end

    if claimedTime > predictedBounceAbs then
        return { ok = false, reason = "Hit arrived after predicted bounce" }
    end

    local first = getFirstSample(baked)
    if not first then
        return { ok = false, reason = "No first sample in baked payload" }
    end

    local radius = baked.radius or BallPhysics.DefaultBallRadius or 0.25
    local rebaked = BallPhysics.Bake(first.p, first.v, radius, baked.stepHz)

    local elapsed = math.max(0, claimedTime - currentStartTime)
    local predictedSample = BallPhysics.SampleAtTime(currentBaked, elapsed)
    local delta = (predictedSample and predictedSample.p and first.p) and (predictedSample.p - first.p).Magnitude or math.huge
    if delta > 10 then
        return { ok = false, reason = string.format("Hit position deviates from predicted path by %.2f studs", delta) }
    end

    local impact = nextImpactOfKind(rebaked, "Court")
    if not impact then
        return { ok = false, reason = "Rebaked trajectory never hits court (out or net)" }
    end

    return {
        ok = true,
        baked = rebaked,
        time = claimedTime,
        info = string.format("Valid hit by %s at t=%.3f | delta=%.2f | nextBounce=%.3f @ %s", player.Name, claimedTime, delta, impact.t, formatVector(impact.pos)),
    }
end

function Point:_awaitHit(expectedPlayer: Player, windowStart: number, windowEnd: number, predictedBounceAbs: number, currentBaked, currentStartTime: number, inbox)
    while now() <= windowEnd do
        for i = #inbox, 1, -1 do
            local eventData = inbox[i]
            if eventData.serverTime >= windowStart and eventData.serverTime <= windowEnd then
                local validation = self:_validateHit(eventData, expectedPlayer, windowStart, windowEnd, predictedBounceAbs, currentBaked, currentStartTime)
                if validation.ok then
                    table.remove(inbox, i)
                    return validation
                else
                    table.remove(inbox, i)
                end
            end
        end
        task.wait(0.05)
    end
    return nil
end

local function terminalNonCourtImpact(baked)
    if not baked or not baked.impacts then return nil end
    for _, impact in ipairs(baked.impacts) do
        if impact.kind ~= "Court" then
            return impact
        else
            return nil
        end
    end
    return nil
end

local function sideOfNet(netModel: Model?, pos: Vector3?): string
    if not netModel or not pos then return "Unknown" end
    local netPart = netModel.PrimaryPart or netModel:FindFirstChildWhichIsA("BasePart")
    if not netPart then return "Unknown" end
    local dir = pos.Z - netPart.Position.Z
    if math.abs(dir) < 0.1 then return "OnNet" end
    return dir > 0 and "Positive" or "Negative"
end

local function decideDeadBallWinner(lastHitterIndex: number, reason: string)
    local winner = lastHitterIndex == 1 and 2 or 1
    return winner, reason .. string.format(" | Winner=P%d", winner)
end

function Point:Start(): number
    local serverIndex = self.Server
    local receiverIndex = (serverIndex == 1) and 2 or 1

    local EnterMatch = self.RemoteController:AddOrGetEvent("EnterMatch")
    EnterMatch:FireClient(self.Player1)
    EnterMatch:FireClient(self.Player2)

    local ServePlayer = self.Server == 1 and self.Player1 or self.Player2
    local ReceivePlayer = (ServePlayer == self.Player1 and self.Player2) or self.Player1
    local ServeChar = ServePlayer.Character
    local ReceiveChar = ReceivePlayer.Character

    local function resetServeBoxes()
        for _, box in pairs({ self.Court.ServeBox1R, self.Court.ServeBox1L, self.Court.ServeBox2R, self.Court.ServeBox2L }) do
            clearBox(box) -- UPDATED: clears transparency/visibility
        end
    end

    local function enableServeBox(serveBox)
        for _, v in pairs(serveBox:GetChildren()) do
            if v:IsA("Part") then
                v.CanCollide = true
                v.Transparency = 0.9
                v.Color = Color3.new(1,1,1)
            end
        end
    end

    -- ADDED: determine which box belongs to server
    local function getServerBox()
        if serverIndex == 1 then
            return (self.Side == "Deuce") and self.Court.ServeBox1R or self.Court.ServeBox1L
        else
            return (self.Side == "Deuce") and self.Court.ServeBox2R or self.Court.ServeBox2L
        end
    end

    resetServeBoxes()
    enableServeBox(getServerBox())

    ServeChar:SetPrimaryPartCFrame(self.Side == "Deuce" and self.Court.ServeR1.CFrame or self.Court.ServeL1.CFrame)
    ReceiveChar:SetPrimaryPartCFrame(self.Side == "Deuce" and self.Court.ServeR2.CFrame or self.Court.ServeL2.CFrame)

    local hitInbox = {}
    local trajConn = BallTrajectory.OnServerEvent:Connect(function(player: Player, payload: any)
        if typeof(payload) ~= "table" or typeof(payload.baked) ~= "table" then
            return
        end
        table.insert(hitInbox, { player = player, payload = payload, serverTime = now() })
    end)

    local function cleanup()
        if trajConn then trajConn:Disconnect() end
    end

    local function bakeToss()
        local hrp = ServeChar:WaitForChild("HumanoidRootPart")
        local forwardOffset = hrp.CFrame.LookVector * 2.5
        local rightOffset = hrp.CFrame.RightVector * 3
        local spawnPosition = hrp.Position + forwardOffset + rightOffset
        local bakedPath = BallPhysics.Bake(spawnPosition, Vector3.new(0, 32, 0), nil)
        return bakedPath, spawnPosition
    end

    local function broadcast(baked, hitter: Player?)
        BallTrajectory:FireAllClients({
            baked = baked,
            fromUserId = hitter and hitter.UserId or nil,
            lastHitUserId = hitter and hitter.UserId or nil,
        })
    end

    local currentBaked, currentStartTime
    local lastHitterIndex = serverIndex
    local faults = 0
    local winnerIndex: number? = nil
    local endReason = ""

    -- ================= SERVE LOGIC =================
    for attempt = 1, 2 do
        resetServeBoxes()
        enableServeBox(getServerBox())

        currentBaked = select(1, bakeToss())
        currentStartTime = now()
        broadcast(currentBaked, nil)

        local bounceImpact = nextImpactOfKind(currentBaked, "Court")
        local predictedBounceAbs = bounceImpact and (currentStartTime + bounceImpact.t) or (currentStartTime + 2)
        local windowStart = currentStartTime
        local windowEnd = predictedBounceAbs + 1

        local hitResult = self:_awaitHit(ServePlayer, windowStart, windowEnd, predictedBounceAbs, currentBaked, currentStartTime, hitInbox)

        if hitResult and hitResult.ok then
            warn("VALID SERVE by " .. ServePlayer.Name) -- ADDED LOGGING

            currentBaked = hitResult.baked
            currentStartTime = hitResult.time
            broadcast(currentBaked, ServePlayer)

            local firstImpact = currentBaked.impacts and currentBaked.impacts[1] or nil
            if not firstImpact or firstImpact.kind ~= "Court" then
                faults += 1
                warn("INVALID SERVE (did not hit court)") -- ADDED LOGGING
                setBoxRed(getServerBox())                -- ADDED
                task.wait(5)                            -- ADDED DELAY
            else
                break -- serve was valid
            end

        else
            faults += 1
            warn("INVALID SERVE: no valid hit received") -- ADDED
            setBoxRed(getServerBox())                    -- ADDED
            task.wait(5)                                -- ADDED DELAY
        end

        if faults >= 2 then
            winnerIndex = receiverIndex
            endReason = "Double fault"
            break
        end
    end

    if winnerIndex then
        cleanup()
        return winnerIndex
    end

    -- serve was valid → clear red
    resetServeBoxes()
    enableServeBox(getServerBox())

    -- ================= RECEIVER WINDOW =================
    local serveBounce = nextImpactOfKind(currentBaked, "Court")
    local serveBounceAbs = serveBounce and (currentStartTime + serveBounce.t) or (currentStartTime + 1)
    local receiverWindowEnd = serveBounceAbs + 1

    local hitResult = self:_awaitHit(ReceivePlayer, currentStartTime, receiverWindowEnd, serveBounceAbs, currentBaked, currentStartTime, hitInbox)
    if hitResult and hitResult.ok then
        currentBaked = hitResult.baked
        currentStartTime = hitResult.time
        broadcast(currentBaked, ReceivePlayer)
    else
        local secondBounce = nextImpactOfKind(currentBaked, "Court", serveBounce and serveBounce.t or 0)
        local secondBounceAbs = secondBounce and (currentStartTime + secondBounce.t) or (receiverWindowEnd + 0.5)
        while now() < secondBounceAbs do task.wait(0.05) end
        cleanup()
        return serverIndex
    end

    -- ================= RALLY LOOP =================
    local expectedIndex = serverIndex
    while true do
        local expectedPlayer = expectedIndex == 1 and self.Player1 or self.Player2
        local nextBounce = nextImpactOfKind(currentBaked, "Court")
        local bounceAbs = nextBounce and (currentStartTime + nextBounce.t) or (currentStartTime + 0.5)
        local windowEnd = bounceAbs + 1

        local hit = self:_awaitHit(expectedPlayer, currentStartTime, windowEnd, bounceAbs, currentBaked, currentStartTime, hitInbox)
        if hit and hit.ok then
            currentBaked = hit.baked
            currentStartTime = hit.time
            broadcast(currentBaked, expectedPlayer)
            expectedIndex = expectedIndex == 1 and 2 or 1
        else
            local secondBounce = nextImpactOfKind(currentBaked, "Court", nextBounce and nextBounce.t or 0)
            local secondAbs = secondBounce and (currentStartTime + secondBounce.t) or (windowEnd + 0.5)
            while now() < secondAbs do task.wait(0.05) end
            winnerIndex, endReason = decideDeadBallWinner(expectedIndex, "Double bounce / missed return")
            break
        end

        local badImpact = terminalNonCourtImpact(currentBaked)
        if badImpact then
            winnerIndex, endReason = decideDeadBallWinner(expectedIndex, "Out / net")
            break
        end
    end

    cleanup()
    return winnerIndex or receiverIndex
end

return Point
