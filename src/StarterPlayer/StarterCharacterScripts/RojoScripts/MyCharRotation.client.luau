--!nocheck
-- StarterCharacterScripts/SharedTorsoHeadYawPitch.cameraBased.client.lua
-- R15 ONLY. Local player: compute camera-based total yaw/pitch, split across Waist/Neck,
-- apply locally (C0 or Transform per config), and PUBLISH total yaw/pitch to server
-- via ReplicatedStorage.CharRotation (UnreliableRemoteEvent/RemoteEvent).
-- Other clients will render you by re-splitting the totals their side.

-------------------------
-- CONFIG
-------------------------
-- Yaw caps
local TOTAL_MAX_YAW_DEG: number = 100
local TORSO_MAX_YAW_DEG: number = 20
local HEAD_MAX_YAW_DEG:  number = 55

-- Pitch caps
local TOTAL_MAX_PITCH_DEG: number = 90
local TORSO_MAX_PITCH_DEG: number = 35
local HEAD_MAX_PITCH_DEG:  number = 55

-- Live PitchOffset from ClientProfile
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClientProfile = nil
pcall(function()
	ClientProfile = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ClientProfile"))
end)

local currentPitchOffset: number = math.rad(18.0) -- default
do
	if ClientProfile and ClientProfile.PitchOffset and ClientProfile.PitchOffset:IsA("NumberValue") then
		-- Wait up to 10s for value to initialize
		local waited = 0
		while ClientProfile.PitchOffset.Value == nil and waited < 10 do
			task.wait(0.5)
			waited += 0.5
		end
		local v = tonumber(ClientProfile.PitchOffset.Value)
		if v then
			currentPitchOffset = math.rad(v)
		end
		-- Update live
		ClientProfile.PitchOffset.Changed:Connect(function(newVal: number)
			if typeof(newVal) == "number" then
				currentPitchOffset = math.rad(newVal)
				--print("[CameraBased] PitchOffset updated:", newVal)
			end
		end)
	else
		warn("[CameraBased] ClientProfile.PitchOffset not found, using default 18.0")
	end
end

-- Choose how to write the rotation:
local USE_C0_OVERRIDE: boolean = true
local APPLY_AFTER_ANIMS: boolean = true

-- Smoothing
local SMOOTH_SPEED_YAW: number = 18
local SMOOTH_SPEED_PITCH: number = 18

-- Networking
local NET_SEND_RATE_HZ: number = 20
local NET_MIN_INTERVAL: number = 1.0 / NET_SEND_RATE_HZ
local NET_QUANTIZE: number = 1e-3

local DEBUG: boolean = false

-------------------------
-- SERVICES / UTILS
-------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local function clamp(x: number, lo: number, hi: number): number
	return (x < lo) and lo or ((x > hi) and hi or x)
end

local function radians(deg: number): number
	return deg * math.pi / 180
end

local TOTAL_MAX_YAW_RAD:     number = radians(TOTAL_MAX_YAW_DEG)
local TORSO_MAX_YAW_RAD:     number = radians(TORSO_MAX_YAW_DEG)
local HEAD_MAX_YAW_RAD:      number = radians(HEAD_MAX_YAW_DEG)

local TOTAL_MAX_PITCH_RAD:   number = radians(TOTAL_MAX_PITCH_DEG)
local TORSO_MAX_PITCH_RAD:   number = radians(TORSO_MAX_PITCH_DEG)
local HEAD_MAX_PITCH_RAD:    number = radians(HEAD_MAX_PITCH_DEG)

local function smoothToward(current: number, target: number, dt: number, speed: number): number
	local alpha = 1 - math.exp(-speed * dt)
	return current + (target - current) * alpha
end

local function signedAngleXZ(a: Vector3, b: Vector3): number
	local crossY = a.X * b.Z - a.Z * b.X
	local dot = a.X * b.X + a.Z * b.Z
	return -math.atan2(crossY, dot)
end

local function horizUnit(v: Vector3): (Vector3, number)
	local m = math.sqrt(v.X * v.X + v.Z * v.Z)
	if m > 1e-6 then
		return Vector3.new(v.X / m, 0, v.Z / m), m
	else
		return Vector3.new(0, 0, 1), 0
	end
end

local TWO_PI: number = math.pi * 2
local function unwrapNear(a: number, ref: number): number
	local k = math.floor((ref - a) / TWO_PI + 0.5)
	return a + k * TWO_PI
end

local function findWaistM6D(char: Model): Motor6D?
	local upperTorso = char:FindFirstChild("UpperTorso")
	local lowerTorso = char:FindFirstChild("LowerTorso")
	if not upperTorso or not lowerTorso then return nil end
	local named = upperTorso:FindFirstChild("Waist")
	if named and named:IsA("Motor6D") then
		return named
	end
	for _, inst in ipairs(upperTorso:GetChildren()) do
		if inst:IsA("Motor6D") then
			local m = inst :: Motor6D
			if (m.Part0 == lowerTorso and m.Part1 == upperTorso) or (m.Part0 == upperTorso and m.Part1 == lowerTorso) then
				return m
			end
		end
	end
	for _, inst in ipairs(lowerTorso:GetChildren()) do
		if inst:IsA("Motor6D") then
			local m = inst :: Motor6D
			if (m.Part0 == lowerTorso and m.Part1 == upperTorso) or (m.Part0 == upperTorso and m.Part1 == lowerTorso) then
				return m
			end
		end
	end
	return nil
end

local function findNeckM6D(char: Model): Motor6D?
	local upperTorso = char:FindFirstChild("UpperTorso")
	local head = char:FindFirstChild("Head")
	if not upperTorso or not head then return nil end
	local named = upperTorso:FindFirstChild("Neck")
	if named and named:IsA("Motor6D") then
		return named
	end
	for _, inst in ipairs(upperTorso:GetChildren()) do
		if inst:IsA("Motor6D") then
			local m = inst :: Motor6D
			if (m.Part0 == upperTorso and m.Part1 == head) or (m.Part0 == head and m.Part1 == upperTorso) then
				return m
			end
		end
	end
	for _, inst in ipairs(head:GetChildren()) do
		if inst:IsA("Motor6D") then
			local m = inst :: Motor6D
			if (m.Part0 == upperTorso and m.Part1 == head) or (m.Part0 == head and m.Part1 == upperTorso) then
				return m
			end
		end
	end
	return nil
end

-------------------------
-- MAIN
-------------------------
local function attachToCharacter(char: Model)
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then error("Humanoid not found; must run under StarterCharacterScripts.") end
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then error("R15 required.") end

	local root: BasePart = char:WaitForChild("HumanoidRootPart") :: BasePart
	local headPart: BasePart = (char:WaitForChild("Head") :: BasePart)

	local waistM6D = findWaistM6D(char)
	if not waistM6D then error("Waist Motor6D not found between LowerTorso and UpperTorso.") end
	waistM6D = waistM6D :: Motor6D

	local neckM6D = findNeckM6D(char)
	if not neckM6D then error("Neck Motor6D not found between UpperTorso and Head.") end
	neckM6D = neckM6D :: Motor6D

	local baseWaistC0: CFrame = waistM6D.C0
	local baseNeckC0:  CFrame = neckM6D.C0

	local curTorsoYaw:   number = 0.0
	local curHeadYaw:    number = 0.0
	local curTorsoPitch: number = 0.0
	local curHeadPitch:  number = 0.0

	local prevTotalYawCont: number = 0.0

	local charRotationEvent = (ReplicatedStorage:WaitForChild("MiscEvents"):WaitForChild("CharRotation") :: any) :: RemoteEvent
	local sendAccumulator: number = 0
	local lastSentYaw: number = 1e9
	local lastSentPitch: number = 1e9

	local alive = true
	local stepName = "SharedTorsoHeadYawPitch_" .. tostring(char)
	local renderConn: RBXScriptConnection? = nil

	local function computeTotals(): (number, number)
		local cam = workspace.CurrentCamera
		if not cam then return 0, 0 end
		local camLook: Vector3 = cam.CFrame.LookVector
		local rootF, rootMag = horizUnit(root.CFrame.LookVector)
		local camF,  camMag  = horizUnit(camLook)
		local yawBasis: Vector3
		if rootMag > 1e-6 and camMag > 1e-6 then
			local facingDot = rootF:Dot(camF)
			if facingDot >= 0 then
				yawBasis = camF
			else
				local toCamXZ, toCamMag = horizUnit(cam.CFrame.Position - headPart.Position)
				yawBasis = (toCamMag > 1e-6) and toCamXZ or (-camF)
			end
		else
			yawBasis = camF
		end
		local yawRaw = signedAngleXZ(rootF, yawBasis)
		local yawCont = unwrapNear(yawRaw, prevTotalYawCont)
		prevTotalYawCont = yawCont
		local yawTotalTarget = clamp(yawCont, -TOTAL_MAX_YAW_RAD, TOTAL_MAX_YAW_RAD)
		if math.abs(yawCont) >= TOTAL_MAX_YAW_RAD - 1e-3 then
			prevTotalYawCont = yawTotalTarget
		end
		local horizLen = math.sqrt(camLook.X * camLook.X + camLook.Z * camLook.Z)
		local rawPitch = ((horizLen > 1e-6) and math.atan2(camLook.Y, horizLen)
			or (camLook.Y >= 0 and math.pi/2 or -math.pi/2))
		local pitchTotalTarget: number = clamp(rawPitch, -TOTAL_MAX_PITCH_RAD, TOTAL_MAX_PITCH_RAD)
		return yawTotalTarget, pitchTotalTarget
	end

	local function reset()
		if USE_C0_OVERRIDE then
			waistM6D.C0 = baseWaistC0
			neckM6D.C0  = baseNeckC0
		else
			waistM6D.Transform = CFrame.new()
			neckM6D.Transform  = CFrame.new()
		end
	end

	humanoid.Died:Connect(function()
		alive = false
		reset()
		if APPLY_AFTER_ANIMS then
			RunService:UnbindFromRenderStep(stepName)
		elseif renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
	end)
	char.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			alive = false
			reset()
			if APPLY_AFTER_ANIMS then
				RunService:UnbindFromRenderStep(stepName)
			elseif renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
		end
	end)
	waistM6D.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			alive = false
			if APPLY_AFTER_ANIMS then
				RunService:UnbindFromRenderStep(stepName)
			elseif renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
		end
	end)
	neckM6D.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			alive = false
			if APPLY_AFTER_ANIMS then
				RunService:UnbindFromRenderStep(stepName)
			elseif renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
		end
	end)

	local function onStep(dt: number)
		if not alive then return end
		if not char.Parent then return end
		local cam = workspace.CurrentCamera
		if not cam then return end

		local yawTotalTarget: number, pitchTotalTarget: number = computeTotals()

		local halfYaw: number = yawTotalTarget * 0.5
		local torsoYawTarget: number = clamp(halfYaw, -TORSO_MAX_YAW_RAD, TORSO_MAX_YAW_RAD)
		local remainingYaw: number = yawTotalTarget - torsoYawTarget
		local headYawTarget: number = clamp(remainingYaw, -HEAD_MAX_YAW_RAD, HEAD_MAX_YAW_RAD)

		local halfPitch: number = pitchTotalTarget * 0.5
		local torsoPitchTarget: number = clamp(halfPitch, -TORSO_MAX_PITCH_RAD, TORSO_MAX_PITCH_RAD)
		local remainingPitch: number = pitchTotalTarget - torsoPitchTarget
		local headPitchTarget: number = clamp(remainingPitch, -HEAD_MAX_PITCH_RAD, HEAD_MAX_PITCH_RAD)

		curTorsoYaw   = smoothToward(curTorsoYaw,   torsoYawTarget,  dt, SMOOTH_SPEED_YAW)
		curHeadYaw    = smoothToward(curHeadYaw,    headYawTarget,   dt, SMOOTH_SPEED_YAW)
		curTorsoPitch = smoothToward(curTorsoPitch, torsoPitchTarget,dt, SMOOTH_SPEED_PITCH)
		curHeadPitch  = smoothToward(curHeadPitch,  headPitchTarget, dt, SMOOTH_SPEED_PITCH)

		if DEBUG then
			--[[print(string.format(
				"YawTot=%.2f, TorsoYaw=%.2f, HeadYaw=%.2f | PitchTot=%.2f, TorsoPitch=%.2f, HeadPitch=%.2f",
				yawTotalTarget, curTorsoYaw, curHeadYaw, pitchTotalTarget, curTorsoPitch, curHeadPitch
			))]]
		end

		if USE_C0_OVERRIDE then
			waistM6D.C0 = baseWaistC0 * CFrame.Angles(0, curTorsoYaw, 0) *
				CFrame.Angles(curTorsoPitch + currentPitchOffset, 0, 0)
			neckM6D.C0  = baseNeckC0  * CFrame.Angles(0, curHeadYaw,  0) *
				CFrame.Angles(curHeadPitch, 0, 0)
		else
			waistM6D.Transform = CFrame.Angles(0, curTorsoYaw, 0) *
				CFrame.Angles(curTorsoPitch + currentPitchOffset, 0, 0)
			neckM6D.Transform  = CFrame.Angles(0, curHeadYaw,  0) *
				CFrame.Angles(curHeadPitch, 0, 0)
		end

		sendAccumulator += dt
		if sendAccumulator >= NET_MIN_INTERVAL then
			sendAccumulator -= NET_MIN_INTERVAL
			local qYaw = math.floor(yawTotalTarget / NET_QUANTIZE + 0.5) * NET_QUANTIZE
			local qPit = math.floor(pitchTotalTarget / NET_QUANTIZE + 0.5) * NET_QUANTIZE
			if math.abs(qYaw - lastSentYaw) > 0 or math.abs(qPit - lastSentPitch) > 0 then
				lastSentYaw = qYaw
				lastSentPitch = qPit
				charRotationEvent:FireServer(qYaw, qPit)
			end
		end
	end

	if APPLY_AFTER_ANIMS then
		RunService:BindToRenderStep(stepName, Enum.RenderPriority.Last.Value, onStep)
	else
		renderConn = RunService.RenderStepped:Connect(onStep)
	end
end

if player.Character then
	task.defer(attachToCharacter, player.Character)
end
player.CharacterAdded:Connect(attachToCharacter)
