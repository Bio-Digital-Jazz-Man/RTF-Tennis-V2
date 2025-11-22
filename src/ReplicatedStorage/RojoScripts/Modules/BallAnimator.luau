-- BallAnimator.lua
-- Local module to animate a baked tennis-ball trajectory on the client.

--!nocheck

local Replicated   = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local Workspace    = game:GetService("Workspace")

-- ===== SETTINGS =====
local FLASH_ON_IMPACT = true  -- master toggle

-- O(1) lookup table of valid court part names
local VALID_FLASH_PARTS: {[string]:boolean} = {
    ["Back1"] = true,
    ["Back2"] = true,
    ["L1"] = true,
    ["L2"] = true,
    ["R1"] = true,
    ["R2"] = true,
    ["UL1"] = true,
    ["UL2"] = true,
    ["UR1"] = true,
    ["UR2"] = true,
}

export type BakedSample = { t:number, p:Vector3, v:Vector3, state:number, event:string? }
export type BakedPath   = {
    stepHz:number,
    radius:number,
    samples:{BakedSample},
    totalTime:number,
    impacts:{ {t:number, kind:string, pos:Vector3, state:number, hit:BasePart?} }
}

export type PlayOptions = {
    Parent: Instance?,
    DestroyOnStop: boolean?,
    StartOffset: number?,
}

export type PlayHandle = {
    Stop: (self:any)->(),
    IsPlaying: (self:any)->boolean,
    GetElapsed: (self:any)->number,
    GetPart: (self:any)->BasePart?,
}

local M = {}

-- ===== Trail visuals =====
local TRAIL_LIFETIME       = 1.0
local TRAIL_COLOR          = ColorSequence.new(Color3.fromRGB(255, 255, 255))
local TRAIL_TRANSPARENCY   = NumberSequence.new(0, 1)
local TRAIL_WIDTH          = NumberSequence.new(0.35, 0)

local registry: {[BasePart]: {conn: RBXScriptConnection?, playing: boolean, elapsed: number, radius: number, R: CFrame}} =
    setmetatable({}, {__mode = "k"})

-- ===== Helpers =====
local function ensureTrail(part: BasePart, radius: number)
    local a0 = part:FindFirstChild("TrailAttach0") :: Attachment?
    local a1 = part:FindFirstChild("TrailAttach1") :: Attachment?

    if not a0 then
        a0 = Instance.new("Attachment")
        a0.Name = "TrailAttach0"
        a0.Position = Vector3.new(0,  radius, 0)
        a0.Parent = part
    else
        a0.Position = Vector3.new(0, radius, 0)
    end

    if not a1 then
        a1 = Instance.new("Attachment")
        a1.Name = "TrailAttach1"
        a1.Position = Vector3.new(0, -radius, 0)
        a1.Parent = part
    else
        a1.Position = Vector3.new(0, -radius, 0)
    end

    local trail = part:FindFirstChildOfClass("Trail")
    if not trail then
        trail = Instance.new("Trail")
        trail.Name = "BallTrail"
        trail.FaceCamera = true
        trail.Attachment0 = a0
        trail.Attachment1 = a1
        trail.Lifetime = TRAIL_LIFETIME
        trail.Color = TRAIL_COLOR
        trail.Transparency = TRAIL_TRANSPARENCY
        trail.WidthScale = TRAIL_WIDTH
        trail.Enabled = true
        trail.Parent = part
    else
        trail.Attachment0 = a0
        trail.Attachment1 = a1
        trail.Lifetime = TRAIL_LIFETIME
        trail.Color = TRAIL_COLOR
        trail.Transparency = TRAIL_TRANSPARENCY
        trail.WidthScale = TRAIL_WIDTH
        trail.Enabled = true
    end
end

local function updateRotationFromVelocity(vel: Vector3, radius: number, dt: number, R: CFrame): CFrame
    local horizVel = Vector3.new(vel.X, 0, vel.Z)
    if horizVel.Magnitude > 1e-3 then
        local rollAxis = Vector3.yAxis:Cross(horizVel).Unit
        local rollSpeed = horizVel.Magnitude / math.max(radius, 1e-3)
        return CFrame.fromAxisAngle(rollAxis, rollSpeed * dt) * R
    end
    return R
end

local function sampleAtTime(baked: BakedPath, tt: number): BakedSample
    if tt <= 0 then return baked.samples[1] end
    local n = #baked.samples
    local last = baked.samples[n]
    if tt >= last.t then return last end
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if baked.samples[mid].t < tt then lo = mid + 1 else hi = mid end
    end
    return baked.samples[lo]
end

local function stopForPart(part: BasePart, destroy: boolean?)
    local rec = registry[part]
    if rec then
        rec.playing = false
        if rec.conn then rec.conn:Disconnect() rec.conn = nil end
        registry[part] = nil
    end
    if destroy and part and part.Parent then
        part:Destroy()
    end
end

-- Build a whitelist of court parts we’re allowed to flash (by name)
local flashWhitelistCache = nil
local function getFlashWhitelist(): {Instance}
    if flashWhitelistCache then return flashWhitelistCache end
    local list = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") and VALID_FLASH_PARTS[inst.Name] then
            table.insert(list, inst)
        end
    end
    flashWhitelistCache = list
    return list
end

-- ===== Flashing logic =====
local debugValue = Replicated:WaitForChild("Debug") :: BoolValue

local function flashCourtPart(hit: BasePart?, atPos: Vector3?)
    if not FLASH_ON_IMPACT then return end
    if not debugValue.Value then return end

    local target: BasePart? = nil

    if hit and hit:IsA("BasePart") and VALID_FLASH_PARTS[hit.Name] then
        target = hit
    elseif atPos then
        -- Fallback: find the court part under/near the impact position
        local p = RaycastParams.new()
        p.FilterType = Enum.RaycastFilterType.Whitelist
        p.FilterDescendantsInstances = getFlashWhitelist()
        local probe = Workspace:Raycast(atPos + Vector3.new(0, 1000, 0), Vector3.new(0, -5000, 0), p)
        if probe and probe.Instance and probe.Instance:IsA("BasePart") and VALID_FLASH_PARTS[probe.Instance.Name] then
            target = probe.Instance
        end
    end

    if not target then return end

    -- Store original attributes ONCE
    if target:GetAttribute("OrigMaterial") == nil then
        target:SetAttribute("OrigMaterial", target.Material.Name)
        target:SetAttribute("OrigColorR", target.Color.R)
        target:SetAttribute("OrigColorG", target.Color.G)
        target:SetAttribute("OrigColorB", target.Color.B)
    end

    target.Material = Enum.Material.Neon
    target.Color = Color3.fromRGB(113, 108, 206)

    task.delay(0.2, function()
        if target and target.Parent then
            local matName = target:GetAttribute("OrigMaterial")
            local r = target:GetAttribute("OrigColorR")
            local g = target:GetAttribute("OrigColorG")
            local b = target:GetAttribute("OrigColorB")
            if matName and r and g and b then
                local ok, mat = pcall(function() return Enum.Material[matName] end)
                if ok and mat then
                    target.Material = mat
                end
                target.Color = Color3.new(r, g, b)
            end
        end
    end)
end

-- ===== Core driver =====
local function drivePart(part: BasePart, baked: BakedPath, startOffset: number?, destroyOnStop: boolean?)
    stopForPart(part, false)

    local r = baked.radius
    if not r or r <= 0 then
        r = math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
        if r <= 0 then r = 0.25 end
    end
    ensureTrail(part, r)

    local rec = {conn=nil :: RBXScriptConnection?, playing=true, elapsed=0 - (startOffset or 0), radius=r, R=CFrame.identity}
    registry[part] = rec

    local impactIndex = 1
    local impacts = baked.impacts or {}

    do
        local s0 = baked.samples[1]
        if s0 then
            part.Anchored = true
            part.CFrame  = CFrame.new(s0.p) * rec.R
            part:SetAttribute("BallSpeed", s0.v.Magnitude)
        end
    end

    rec.conn = RunService.RenderStepped:Connect(function(dt)
        if not rec.playing then
            if rec.conn then rec.conn:Disconnect() rec.conn = nil end
            return
        end
        if not part or not part.Parent then
            rec.playing = false
            if rec.conn then rec.conn:Disconnect() rec.conn = nil end
            return
        end

        rec.elapsed += dt
        local s = sampleAtTime(baked, rec.elapsed)
        local pos, vel = s.p, s.v

        part:SetAttribute("BallSpeed", vel.Magnitude)
        rec.R = updateRotationFromVelocity(vel, rec.radius, dt, rec.R)
        part.CFrame = CFrame.new(pos) * rec.R

        -- process impacts
        while impactIndex <= #impacts and rec.elapsed >= impacts[impactIndex].t do
            local imp = impacts[impactIndex]
            if imp.kind == "Court" then
                -- Use the ref if present; fallback to position-based raycast if not
                flashCourtPart(imp.hit, imp.pos)
            end
            impactIndex += 1
        end

        if rec.elapsed >= baked.totalTime or s.event == "Stop" or s.event == "Cull" then
            rec.playing = false
            part.CFrame = CFrame.new(pos) * rec.R
            if destroyOnStop and part and part.Parent then
                part:Destroy()
            end
            if rec.conn then rec.conn:Disconnect() rec.conn = nil end
            registry[part] = nil
        end
    end)

    local handle: PlayHandle = {
        Stop = function()
            stopForPart(part, destroyOnStop)
        end,
        IsPlaying = function() return rec.playing end,
        GetElapsed = function() return math.max(0, rec.elapsed) end,
        GetPart = function() return part end,
    }
    return handle
end

-- ===== Public API =====
function M.Play(baked: BakedPath, opts: PlayOptions?): PlayHandle
    local template = Replicated:WaitForChild("TENNISBALL_TEMP") :: BasePart
    local parent = (opts and opts.Parent) or Workspace
    local destroyOnStop = (opts and opts.DestroyOnStop ~= nil) and opts.DestroyOnStop or true
    local startOffset = (opts and opts.StartOffset) or 0

    local ball = template:Clone()
    ball.Parent = parent
    ball.Anchored = true

    return drivePart(ball, baked, startOffset, destroyOnStop)
end

function M.PlayOnPart(part: BasePart, baked: BakedPath, opts: PlayOptions?): PlayHandle
    local destroyOnStop = (opts and opts.DestroyOnStop ~= nil) and opts.DestroyOnStop or true
    local startOffset = (opts and opts.StartOffset) or 0
    return drivePart(part, baked, startOffset, destroyOnStop)
end

function M.StopForPart(part: BasePart)
    stopForPart(part, false)
end

return M
