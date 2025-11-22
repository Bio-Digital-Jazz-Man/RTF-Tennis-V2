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
    print(Game, self.ServerManager)
    self.RemoteController = self.ServerManager.RemoteController

    return self
end

-- Validate a reported hit against the current rally window.
-- Returns { ok=true, baked=<server-baked>, time=<hitTime>, info=<string> } or { ok=false, reason=<string> }
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

    -- Compare claimed contact position to where the authoritative trajectory says the ball should be
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

-- Process incoming hit reports and return the first valid one inside the window.
function Point:_awaitHit(expectedPlayer: Player, windowStart: number, windowEnd: number, predictedBounceAbs: number, currentBaked, currentStartTime: number, inbox)
    print(string.format("[POINT] Awaiting hit from %s | windowStart=%.3f | windowEnd=%.3f | predictedBounce=%.3f", expectedPlayer.Name, windowStart, windowEnd, predictedBounceAbs))

    while now() <= windowEnd do
        for i = #inbox, 1, -1 do
            local eventData = inbox[i]
            if eventData.serverTime >= windowStart and eventData.serverTime <= windowEnd then
                local validation = self:_validateHit(eventData, expectedPlayer, windowStart, windowEnd, predictedBounceAbs, currentBaked, currentStartTime)
                if validation.ok then
                    table.remove(inbox, i)
                    print("[POINT] Accepted hit | " .. validation.info)
                    return validation
                else
                    print(string.format("[POINT] Rejected hit from %s | %s", eventData.player.Name, validation.reason))
                    table.remove(inbox, i)
                end
            end
        end
        task.wait(0.05)
    end

    print(string.format("[POINT] Hit window closed for %s (no valid hit).", expectedPlayer.Name))
    return nil
end

-- Determine if a baked path dies before a court impact (net/out).
local function terminalNonCourtImpact(baked)
    if not baked or not baked.impacts then return nil end
    for _, impact in ipairs(baked.impacts) do
        if impact.kind ~= "Court" then
            return impact
        else
            return nil -- first impact is court, so not terminal non-court
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

-- Decide the winner based on a dead ball.
local function decideDeadBallWinner(lastHitterIndex: number, reason: string)
    local winner = lastHitterIndex == 1 and 2 or 1
    return winner, reason .. string.format(" | Winner=P%d", winner)
end

function Point:Start(): number
    local serverIndex = self.Server
    local receiverIndex = (serverIndex == 1) and 2 or 1

    print(("\n[POINT] Start | Server=P%d | Side=%s | Mode=%s"):format(serverIndex, self.Side, self.Params.name))

    local EnterMatch = self.RemoteController:AddOrGetEvent("EnterMatch")
    EnterMatch:FireClient(self.Player1)
    EnterMatch:FireClient(self.Player2)

    local ServePlayer = self.Server == 1 and self.Player1 or self.Player2
    local ReceivePlayer = (ServePlayer == self.Player1 and self.Player2) or self.Player1
    local ServeChar = ServePlayer.Character
    local ReceiveChar = ReceivePlayer.Character

    local function resetServeBoxes()
        for _, box in pairs({ self.Court.ServeBox1R, self.Court.ServeBox1L, self.Court.ServeBox2R, self.Court.ServeBox2L }) do
            for _, v in pairs(box:GetChildren()) do
                if v:IsA("Part") then
                    v.CanCollide = false
                    v.Transparency = 1
                end
            end
        end
    end

    local function setServeBox(serveBox)
        for _, v in pairs(serveBox:GetChildren()) do
            if v:IsA("Part") then
                v.CanCollide = true
                v.Transparency = 0.9
            end
        end
    end

    resetServeBoxes()
    if self.Side == "Deuce" then
        setServeBox(self.Court.ServeBox1R)
        ServeChar:SetPrimaryPartCFrame(self.Court.ServeR1.CFrame)
        ReceiveChar:SetPrimaryPartCFrame(self.Court.ServeR2.CFrame)
    else
        setServeBox(self.Court.ServeBox1L)
        ServeChar:SetPrimaryPartCFrame(self.Court.ServeL1.CFrame)
        ReceiveChar:SetPrimaryPartCFrame(self.Court.ServeL2.CFrame)
    end

    local hitInbox = {}
    local trajConn = BallTrajectory.OnServerEvent:Connect(function(player: Player, payload: any)
        if typeof(payload) ~= "table" or typeof(payload.baked) ~= "table" then
            return
        end
        table.insert(hitInbox, { player = player, payload = payload, serverTime = now() })
        print(string.format("[POINT] Received baked trajectory from %s | samples=%d", player.Name, #payload.baked.samples))
    end)

    local function cleanup()
        if trajConn then
            trajConn:Disconnect()
        end
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
    local history: { string } = {}

    local function logStep(msg)
        table.insert(history, msg)
        print("[POINT] " .. msg)
    end

    -- ================= SERVE LOGIC =================
    for attempt = 1, 2 do
        logStep(string.format("Serve attempt %d begins", attempt))
        currentBaked = select(1, bakeToss())
        currentStartTime = now()
        broadcast(currentBaked, ServePlayer)
        debugImpacts("[POINT][SERVE] Toss", currentBaked)

        local bounceImpact = nextImpactOfKind(currentBaked, "Court")
        local predictedBounceAbs = bounceImpact and (currentStartTime + bounceImpact.t) or (currentStartTime + 2)
        local windowStart = currentStartTime
        local windowEnd = predictedBounceAbs + 1

        logStep(string.format("Serve window open | bounceT=%.3f @ %s | windowEnd=%.3f", predictedBounceAbs, formatVector(bounceImpact and bounceImpact.pos), windowEnd))

        local hitResult = self:_awaitHit(ServePlayer, windowStart, windowEnd, predictedBounceAbs, currentBaked, currentStartTime, hitInbox)
        if hitResult and hitResult.ok then
            currentBaked = hitResult.baked
            currentStartTime = hitResult.time
            lastHitterIndex = serverIndex
            broadcast(currentBaked, ServePlayer)
            debugImpacts("[POINT][SERVE] After hit", currentBaked)

            local firstImpact = currentBaked.impacts and currentBaked.impacts[1] or nil
            if not firstImpact then
                winnerIndex, endReason = decideDeadBallWinner(serverIndex, "Serve produced no impacts (out)")
                break
            end

            if firstImpact.kind ~= "Court" then
                logStep(string.format("Serve hit invalid: first impact %s", tostring(firstImpact.kind)))
                faults += 1
            else
                local side = sideOfNet(self.Court.Net, firstImpact.pos)
                logStep(string.format("Serve landed on %s side | pos=%s | t=%.3f", side, formatVector(firstImpact.pos), firstImpact.t))
                if faults >= 2 then
                    winnerIndex, endReason = receiverIndex, "Double fault before landing"
                end
                -- Valid serve, proceed to receiver window
                break
            end
        else
            faults += 1
            logStep(string.format("Serve fault: no valid hit | attempt=%d | faults=%d", attempt, faults))
        end

        if faults >= 2 then
            winnerIndex, endReason = receiverIndex, "Double fault (no serve contact)"
            break
        end
    end

    if winnerIndex then
        cleanup()
        logStep(string.format("Point ended early | %s", endReason))
        print(("[POINT] Complete | Winner=P%d, Loser=P%d"):format(winnerIndex, winnerIndex == 1 and 2 or 1))
        print("[POINT] History:\n\t" .. table.concat(history, "\n\t"))
        return winnerIndex
    end

    -- Ensure we still have a valid serve trajectory
    local firstImpact = currentBaked.impacts and currentBaked.impacts[1] or nil
    if not firstImpact or firstImpact.kind ~= "Court" then
        winnerIndex, endReason = receiverIndex, "Serve never reached court"
    end

    if winnerIndex then
        cleanup()
        logStep(string.format("Point ended after serve | %s", endReason))
        print(("[POINT] Complete | Winner=P%d, Loser=P%d"):format(winnerIndex, winnerIndex == 1 and 2 or 1))
        print("[POINT] History:\n\t" .. table.concat(history, "\n\t"))
        return winnerIndex
    end

    -- ================= RECEIVER WINDOW =================
    local serveBounce = nextImpactOfKind(currentBaked, "Court")
    local serveBounceAbs = serveBounce and (currentStartTime + serveBounce.t) or (currentStartTime + 1)
    local receiverWindowEnd = serveBounceAbs + 1
    logStep(string.format("Receiver window | expected=%s | bounceT=%.3f @ %s | windowEnd=%.3f", ReceivePlayer.Name, serveBounceAbs, formatVector(serveBounce and serveBounce.pos), receiverWindowEnd))

    local hitResult = self:_awaitHit(ReceivePlayer, currentStartTime, receiverWindowEnd, serveBounceAbs, currentBaked, currentStartTime, hitInbox)
    if hitResult and hitResult.ok then
        currentBaked = hitResult.baked
        currentStartTime = hitResult.time
        lastHitterIndex = receiverIndex
        broadcast(currentBaked, ReceivePlayer)
        debugImpacts("[POINT][RECEIVER] After return", currentBaked)
    else
        -- No valid return; wait for a second bounce to kill the point
        local secondBounce = nextImpactOfKind(currentBaked, "Court", serveBounce and serveBounce.t or 0)
        local secondBounceAbs = secondBounce and (currentStartTime + secondBounce.t) or (receiverWindowEnd + 0.5)
        logStep(string.format("Receiver missed | waiting for second bounce at %.3f", secondBounceAbs))
        while now() < secondBounceAbs do
            task.wait(0.05)
        end
        winnerIndex, endReason = serverIndex, "Receiver failed to return before double bounce"
        cleanup()
        logStep(endReason)
        print(("[POINT] Complete | Winner=P%d, Loser=P%d"):format(winnerIndex, winnerIndex == 1 and 2 or 1))
        print("[POINT] History:\n\t" .. table.concat(history, "\n\t"))
        return winnerIndex
    end

    -- ================= RALLY LOOP =================
    local expectedIndex = serverIndex
    while true do
        local expectedPlayer = expectedIndex == 1 and self.Player1 or self.Player2
        local nextBounce = nextImpactOfKind(currentBaked, "Court")
        local bounceAbs = nextBounce and (currentStartTime + nextBounce.t) or (currentStartTime + 0.5)
        local windowEnd = bounceAbs + 1

        logStep(string.format("Rally window | expected=%s | bounceT=%.3f @ %s | windowEnd=%.3f", expectedPlayer.Name, bounceAbs, formatVector(nextBounce and nextBounce.pos), windowEnd))

        local hit = self:_awaitHit(expectedPlayer, currentStartTime, windowEnd, bounceAbs, currentBaked, currentStartTime, hitInbox)
        if hit and hit.ok then
            currentBaked = hit.baked
            currentStartTime = hit.time
            lastHitterIndex = expectedIndex
            broadcast(currentBaked, expectedPlayer)
            debugImpacts("[POINT][RALLY] After hit", currentBaked)
            expectedIndex = expectedIndex == 1 and 2 or 1
        else
            local secondBounce = nextImpactOfKind(currentBaked, "Court", nextBounce and nextBounce.t or 0)
            local secondAbs = secondBounce and (currentStartTime + secondBounce.t) or (windowEnd + 0.5)
            logStep(string.format("No valid hit from %s | waiting for second bounce at %.3f", expectedPlayer.Name, secondAbs))
            while now() < secondAbs do
                task.wait(0.05)
            end
            winnerIndex, endReason = decideDeadBallWinner(expectedIndex, "Double bounce / missed return")
            break
        end

        local badImpact = terminalNonCourtImpact(currentBaked)
        if badImpact then
            winnerIndex, endReason = decideDeadBallWinner(lastHitterIndex, string.format("Ball died on %s before court", badImpact.kind))
            break
        end
    end

    cleanup()
    winnerIndex = winnerIndex or receiverIndex
    logStep(string.format("Point ended | %s", endReason))
    print(("[POINT] Complete | Winner=P%d, Loser=P%d"):format(winnerIndex, winnerIndex == 1 and 2 or 1))
    print("[POINT] History:\n\t" .. table.concat(history, "\n\t"))
    return winnerIndex
end

return Point
