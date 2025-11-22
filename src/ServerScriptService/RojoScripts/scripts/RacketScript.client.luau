--!nocheck
-- Racket tool: shift-lock camera, swing gates, cooldowns, network-relayed sounds.
-- On contact with a TennisBall, the client bakes a new path **from CAMERA look**
-- (+ pitch in DEGREES from ClientProfile.PitchOffset + lateral pivot)
-- and **retargets that same ball** immediately.

local tool = script.Parent :: Tool

-- Services
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local Workspace          = game:GetService("Workspace")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")

-- Physics + animator (client-side)
local BallPhysics  = require(ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("BallPhysics"))
local BallAnimator = require(ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("BallAnimator"))

local TennisEvents      = ReplicatedStorage:WaitForChild("TennisEvents")
local RacketSoundEvent  = TennisEvents:WaitForChild("RacketSoundEvent") :: RemoteEvent
local TrajEvent         = TennisEvents:WaitForChild("BallTrajectory") :: RemoteEvent

-- Player + camera
local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local mouse  = player:GetMouse()

-- === Hook into ClientProfile for PitchOffset + Camera offsets ===
local ClientProfile = nil
pcall(function()
	ClientProfile = require(ReplicatedStorage:WaitForChild("RojoScripts"):WaitForChild("Modules"):WaitForChild("ClientProfile"))
end)

local currentPitchOffsetDeg: number = 18.0 -- default
local cameraOffsetValues = {
	CameraOffsetX = 0.0,
	CameraOffsetY = 2.0,
	CameraOffsetZ = 0.6,
}
local currentCameraOffset: Vector3 = Vector3.new(
	cameraOffsetValues.CameraOffsetX,
	cameraOffsetValues.CameraOffsetY,
	cameraOffsetValues.CameraOffsetZ
)
local activeShiftLockHumanoid: Humanoid? = nil

local function applyCameraOffsetToActiveHumanoid()
	local humanoid = activeShiftLockHumanoid
	if humanoid and humanoid.Parent then
		humanoid.CameraOffset = currentCameraOffset
	end
end

local function updateCameraOffsetComponent(name: string, value: number)
	if cameraOffsetValues[name] ~= nil then
		cameraOffsetValues[name] = value
		currentCameraOffset = Vector3.new(
			cameraOffsetValues.CameraOffsetX,
			cameraOffsetValues.CameraOffsetY,
			cameraOffsetValues.CameraOffsetZ
		)
		applyCameraOffsetToActiveHumanoid()
	end
end

local function bindNumberValue(valueObj: Instance?, defaultValue: number, apply: (number) -> (), warnMessage: string)
	if typeof(valueObj) == "Instance" and valueObj:IsA("NumberValue") then
		local waited = 0
		while valueObj.Value == nil and waited < 10 do
			task.wait(0.5)
			waited += 0.5
		end
		local initial = tonumber(valueObj.Value)
		if initial == nil then
			initial = defaultValue
		end
		apply(initial)
		valueObj.Changed:Connect(function(newVal: number)
			if typeof(newVal) == "number" then
				apply(newVal)
			end
		end)
	else
		if warnMessage ~= "" then
			warn(warnMessage)
		end
		apply(defaultValue)
	end
end

if ClientProfile then
	bindNumberValue(ClientProfile.PitchOffset, 18.0, function(newVal)
		currentPitchOffsetDeg = newVal
	end, "[Racket] ClientProfile.PitchOffset not found, using default 18.0")

	bindNumberValue(ClientProfile.CameraOffsetX, cameraOffsetValues.CameraOffsetX, function(newVal)
		updateCameraOffsetComponent("CameraOffsetX", newVal)
	end, "[Racket] ClientProfile.CameraOffsetX not found, using default 0.0")

	bindNumberValue(ClientProfile.CameraOffsetY, cameraOffsetValues.CameraOffsetY, function(newVal)
		updateCameraOffsetComponent("CameraOffsetY", newVal)
	end, "[Racket] ClientProfile.CameraOffsetY not found, using default 2.0")

	bindNumberValue(ClientProfile.CameraOffsetZ, cameraOffsetValues.CameraOffsetZ, function(newVal)
		updateCameraOffsetComponent("CameraOffsetZ", newVal)
	end, "[Racket] ClientProfile.CameraOffsetZ not found, using default 0.6")
else
	warn("[Racket] Failed to require ClientProfile; using default settings")
end

-- Character/Humanoid/Animator
local function getCharacter(): Model
	return player.Character or player.CharacterAdded:Wait()
end

local function getHumanoidAndAnimator(): (Humanoid, Animator)
	local character = getCharacter()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return humanoid, animator
end

-- Animations
local bodyIdleAnim = Instance.new("Animation"); bodyIdleAnim.Name = "BodyIdleAnim"
bodyIdleAnim.AnimationId = "rbxassetid://77333343038958"

local armsIdleAnim = Instance.new("Animation"); armsIdleAnim.Name = "ArmsIdleAnim"
armsIdleAnim.AnimationId = "rbxassetid://99136824654076"

local forehandAnim = Instance.new("Animation"); forehandAnim.Name = "ForehandAnim"
forehandAnim.AnimationId = "rbxassetid://122773572058780"

local backhandAnim = Instance.new("Animation"); backhandAnim.Name = "BackhandAnim"
backhandAnim.AnimationId = "rbxassetid://136877470332191"

-- Tracks
local bodyIdle: AnimationTrack? = nil
local armsIdle: AnimationTrack? = nil
local forehand: AnimationTrack? = nil
local backhand: AnimationTrack? = nil

-- Swing gate
local swingBusy, swingActive = false, false
local rightInputConn: RBXScriptConnection? = nil
local wheelConn: RBXScriptConnection? = nil
type SwingKind = "forehand" | "backhand"
local humanoid: Humanoid? = nil

-- =========================
-- POWER / SCROLL CONTROLS
-- =========================
local POWER_MIN: number = 45.0
local POWER_MAX: number = 110.0
local POWER_DEFAULT: number = (POWER_MIN + POWER_MAX) * 0.5 -- baseline (1x)
local POWER_STEP: number = 2.0 -- tweak feel (scroll step size)

-- Volume baselines (1x):
local IMPACT_VOL_1X = 3.0
local SWING_VOL_1X  = 0.4

local currentPower: number = POWER_DEFAULT

local barFrame = player.PlayerGui.StaminaPower.Power.Bar
local powerMeter = barFrame.Meter
local leftMask = barFrame.MaskLeft
local rightMask = barFrame.MaskRight

local function UpdatePowerUI(value: number)
	-- Normalize to 0–1 range
	local alpha = (value - POWER_MIN) / (POWER_MAX - POWER_MIN)
	alpha = math.clamp(alpha, 0, 1)

	powerMeter.Position = UDim2.new(alpha, 0, 0, 0)

	if alpha >= 0.5 then
		local frac = (alpha - 0.5) / 0.5
		leftMask.Size  = UDim2.new(0.5, 0, 1, 0)
		rightMask.Size = UDim2.new(0.5 * (1 - frac), 0, 1, 0)
	else
		local frac = (0.5 - alpha) / 0.5
		leftMask.Size  = UDim2.new(0.5 * (1 - frac), 0, 1, 0)
		rightMask.Size = UDim2.new(0.5, 0, 1, 0)
	end

	-- print(("power updated!: value is %s"):format(tostring(value)))
end

local function resetPowerToDefault()
	currentPower = POWER_DEFAULT
	UpdatePowerUI(currentPower)
end

-- Piecewise map so baseline (POWER_DEFAULT) = 1.0x, min=0.5x, max=2.0x
local function powerToMultiplier(p: number): number
	if p <= POWER_DEFAULT then
		local t = (p - POWER_MIN) / math.max(POWER_DEFAULT - POWER_MIN, 1e-6)
		return math.clamp(0.5 + 0.5 * t, 0.5, 2.0) -- 0.5 -> 1.0
	else
		local t = (p - POWER_DEFAULT) / math.max(POWER_MAX - POWER_DEFAULT, 1e-6)
		return math.clamp(1.0 + 1.0 * t, 0.5, 2.0) -- 1.0 -> 2.0
	end
end

local function multiplierToOctave(m: number): number
	-- Map 0.5x power → 0.95 octave
	--      1.0x power → 1.00 octave
	--      2.0x power → 1.05 octave
	if m <= 1.0 then
		local t = (m - 0.5) / 0.5 -- 0→0.5x, 1→1.0x
		return 0.95 + 0.05 * t    -- 0.95 → 1.0
	else
		local t = (m - 1.0) / 1.0 -- 0→1.0x, 1→2.0x
		return 1.0 + 0.05 * t     -- 1.0 → 1.05
	end
end

local function handleMouseWheel(input: InputObject)
	if not isEquipped then return end
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end

	local dz = input.Position.Z or 0
	if dz > 0 then
		currentPower = math.clamp(currentPower + POWER_STEP, POWER_MIN, POWER_MAX)
		UpdatePowerUI(currentPower)
	elseif dz < 0 then
		currentPower = math.clamp(currentPower - POWER_STEP, POWER_MIN, POWER_MAX)
		UpdatePowerUI(currentPower)
	end
end

local function getHandle(): BasePart?
	local h = tool:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then return h end
	return nil
end

-- Local play + relay with power multiplier
local function playAndRelay(soundName: "Swing" | "Impact")
	local m = powerToMultiplier(currentPower)
	do
		local handle = getHandle()
		if handle then
			local s = handle:FindFirstChild(soundName)
			if s and s:IsA("Sound") then
				local base = (soundName == "Impact") and IMPACT_VOL_1X or SWING_VOL_1X
				s.Volume = base * m
				if soundName == "Swing" then
					s.Volume = SWING_VOL_1X  -- JUST DONT DO IT FOR SWINGS FOR NOW
				end
				local pitch = s:FindFirstChild("PitchShiftSoundEffect")
				if pitch then
					pitch.Octave = multiplierToOctave(m)
					--print("PITCH IS ", pitch.Octave)
				end
				pcall(function() s:Play() end)
			end
		end
	end
	local handleCF: CFrame? = nil
	local h = getHandle(); if h then handleCF = h.CFrame end
	-- Pass power multiplier to server so other clients match loudness
	RacketSoundEvent:FireServer(soundName, tool.Name, handleCF, m)
end

-- Animations
local bodyIdleAnim = Instance.new("Animation"); bodyIdleAnim.Name = "BodyIdleAnim"
bodyIdleAnim.AnimationId = "rbxassetid://77333343038958"

local armsIdleAnim = Instance.new("Animation"); armsIdleAnim.Name = "ArmsIdleAnim"
armsIdleAnim.AnimationId = "rbxassetid://99136824654076"

local forehandAnim = Instance.new("Animation"); forehandAnim.Name = "ForehandAnim"
forehandAnim.AnimationId = "rbxassetid://122773572058780"

local backhandAnim = Instance.new("Animation"); backhandAnim.Name = "BackhandAnim"
backhandAnim.AnimationId = "rbxassetid://136877470332191"

-- Tracks
local bodyIdle: AnimationTrack? = nil
local armsIdle: AnimationTrack? = nil
local forehand: AnimationTrack? = nil
local backhand: AnimationTrack? = nil

local function loadTracks()
	humanoid, animator = getHumanoidAndAnimator()

	if bodyIdle then pcall(function() bodyIdle:Stop(0) end); bodyIdle:Destroy(); bodyIdle = nil end
	if armsIdle then pcall(function() armsIdle:Stop(0) end); armsIdle:Destroy(); armsIdle = nil end
	if forehand then pcall(function() forehand:Stop(0) end); forehand:Destroy(); forehand = nil end
	if backhand then pcall(function() backhand:Stop(0) end); backhand:Destroy(); backhand = nil end

	bodyIdle = animator:LoadAnimation(bodyIdleAnim)
	bodyIdle.Looped = true
	pcall(function() bodyIdle.Priority = Enum.AnimationPriority.Action2 end)

	armsIdle = animator:LoadAnimation(armsIdleAnim)
	armsIdle.Looped = true
	pcall(function() armsIdle.Priority = Enum.AnimationPriority.Action3 end)

	forehand = animator:LoadAnimation(forehandAnim); forehand.Looped = false
	pcall(function() forehand.Priority = Enum.AnimationPriority.Action4 end)
	forehand:GetMarkerReachedSignal("ActiveStart"):Connect(function() swingActive = true end)
	forehand:GetMarkerReachedSignal("ActiveEnd"):Connect(function() swingActive = false end)

	backhand = animator:LoadAnimation(backhandAnim); backhand.Looped = false
	pcall(function() backhand.Priority = Enum.AnimationPriority.Action4 end)
	backhand:GetMarkerReachedSignal("ActiveStart"):Connect(function() swingActive = true end)
	backhand:GetMarkerReachedSignal("ActiveEnd"):Connect(function() swingActive = false end)

	RunService.Heartbeat:Connect(function()
		if not isEquipped or not humanoid then return end
		if bodyIdle then
			local moving = humanoid.MoveDirection.Magnitude > 0
			local jumping = humanoid:GetState() == Enum.HumanoidStateType.Jumping
			if moving or jumping then
				if bodyIdle.IsPlaying then bodyIdle:Stop(0.2) end
			else
				if not bodyIdle.IsPlaying and not swingBusy then bodyIdle:Play(0.2) end
			end
		end
		if armsIdle and not armsIdle.IsPlaying then
			armsIdle:Play(0.2)
		end
	end)
end

local function readCooldown(): number?
	local a: any = script:GetAttribute("SWING_COOLDOWN")
	if typeof(a) ~= "number" then
		a = script:GetAttribute("FOREHAND_COOLDOWN")
	end
	return typeof(a) == "number" and (a :: number) or nil
end

local function playIdle()
	if isEquipped then
		if bodyIdle and not bodyIdle.IsPlaying then bodyIdle:Play(0.1) end
		if armsIdle and not armsIdle.IsPlaying then armsIdle:Play(0.1) end
	end
end

local function stopIdle()
	if bodyIdle and bodyIdle.IsPlaying then bodyIdle:Stop(0.1) end
	if armsIdle and armsIdle.IsPlaying then armsIdle:Stop(0.1) end
end

----------------------------------------------------------------
-- Swing play
----------------------------------------------------------------
local function playSwingOnce(which: SwingKind)
	if swingBusy then return end
	swingBusy = true
	if not bodyIdle or not armsIdle or not forehand or not backhand then loadTracks() end
	stopIdle()

	local track: AnimationTrack? = (which == "backhand") and backhand or forehand
	if not track then
		swingBusy = false
		playIdle()
		return
	end

	local stoppedConn: RBXScriptConnection? = nil
	local function onStopped()
		if stoppedConn then stoppedConn:Disconnect(); stoppedConn = nil end
		swingActive = false

		local function finish()
			if tool.Parent and tool.Parent:IsA("Model") then playIdle() end
			swingBusy = false
		end

		local cd = readCooldown()
		if cd and cd > 0 then
			task.delay(cd, finish)
		else
			finish()
		end
	end

	stoppedConn = track.Stopped:Connect(onStopped)
	local ok = pcall(function()
		track:Play(0.05)
		track:AdjustSpeed(1.0)
		playAndRelay("Swing")
	end)
	if not ok then
		if stoppedConn then stoppedConn:Disconnect() end
		task.defer(function() playIdle(); swingBusy = false end)
	end
end

----------------------------------------------------------------
-- Shift-Lock / Camera Follow
----------------------------------------------------------------

local RENDER_STEP_NAME = "RacketShiftLock"
isEquipped = false

local original = {
	cameraMode = player.CameraMode,
	cameraType = camera.CameraType,
	cameraSubject = camera.CameraSubject,
	autoRotate = false,
	cameraOffset = Vector3.zero,
}

local function forceMouseFreePass()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	mouse.Icon = ""
end

local function unbindFollowLoop()
	pcall(function() RunService:UnbindFromRenderStep(RENDER_STEP_NAME) end)
end

local function bindFollowLoop()
	unbindFollowLoop()
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function()
		if not isEquipped then unbindFollowLoop(); return end
		if camera.CameraType ~= Enum.CameraType.Custom then return end

		local char = player.Character
		if not char or tool.Parent ~= char then
			isEquipped=false; unbindFollowLoop(); forceMouseFreePass(); return
		end
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?; if not root then return end

		local lookXZ = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		if lookXZ.Magnitude < 1e-6 then return end
		lookXZ = lookXZ.Unit

		local pos = root.Position
		root.CFrame = CFrame.new(pos, pos + lookXZ)
	end)
end

local function hardRestoreCamera(humanoid: Humanoid?)
	player.CameraMode   = original.cameraMode
	camera.CameraType   = original.cameraType
	camera.CameraSubject= original.cameraSubject
	if humanoid then
		humanoid.AutoRotate = original.autoRotate
		humanoid.CameraOffset = original.cameraOffset
		if activeShiftLockHumanoid == humanoid then
			activeShiftLockHumanoid = nil
		end
	end
	forceMouseFreePass()
end

local function enableShiftLock()
	local character = getCharacter()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	original.cameraMode   = player.CameraMode
	original.cameraType   = camera.CameraType
	original.cameraSubject= camera.CameraSubject
	original.autoRotate   = humanoid.AutoRotate
	original.cameraOffset = humanoid.CameraOffset

	player.CameraMode = Enum.CameraMode.Classic
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid

	-- Lock zoom while equipped (set both to 10)
	player.CameraMinZoomDistance = 10
	player.CameraMaxZoomDistance = 10

	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = true
	mouse.Icon = "rbxassetid://130187932892169"

	humanoid.CameraOffset = currentCameraOffset
	humanoid.AutoRotate = false
	activeShiftLockHumanoid = humanoid
	applyCameraOffsetToActiveHumanoid()

	bindFollowLoop()
end

local function disableShiftLock()
	unbindFollowLoop()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	mouse.Icon = ""

	-- Restore zoom range when unequipped
	player.CameraMinZoomDistance = 5
	player.CameraMaxZoomDistance = 20

	local character = player.Character
	local humanoid: Humanoid? = character and character:FindFirstChildOfClass("Humanoid") or nil
	if not humanoid then
		activeShiftLockHumanoid = nil
	end
	hardRestoreCamera(humanoid)
end

local function teardownAndUnlock()
	stopIdle()
	if forehand and forehand.IsPlaying then forehand:Stop(0.05) end
	if backhand and backhand.IsPlaying then backhand:Stop(0.05) end
	swingBusy = false; swingActive = false
	isEquipped = false

	if rightInputConn then rightInputConn:Disconnect(); rightInputConn = nil end
	if wheelConn then wheelConn:Disconnect(); wheelConn = nil end

	disableShiftLock()
end

----------------------------------------------------------------
-- Swing contact window gating (0.17s to 0.47s)
----------------------------------------------------------------
local HIT_WINDOW_START = 0.17
local HIT_WINDOW_END   = 0.47

local function isInSwingContactWindow(): boolean
	local function within(t: number?): boolean
		return t ~= nil and t >= HIT_WINDOW_START and t <= HIT_WINDOW_END
	end
	if forehand and forehand.IsPlaying and within(forehand.TimePosition) then return true end
	if backhand and backhand.IsPlaying and within(backhand.TimePosition) then return true end
	return false
end

----------------------------------------------------------------
-- Instant client-side redirect on contact
----------------------------------------------------------------

local HIT_RIGHT_PIVOT  = 0.00
local STEP_HZ          = BallPhysics.DefaultStepHz or 120

local function lastHitWasLocal(ball: BasePart): boolean
	local attr = ball:GetAttribute("LastHitUserId")
	if typeof(attr) == "number" then
		return attr == player.UserId
	elseif typeof(attr) == "string" then
		local asNumber = tonumber(attr)
		return asNumber ~= nil and asNumber == player.UserId
	end
	return false
end

local function cameraHitDirection(): Vector3
	local cf = camera.CFrame
	local baseDir = cf.LookVector
	local pitchRad = math.rad(currentPitchOffsetDeg)
	local pitchedDir = (CFrame.fromAxisAngle(cf.RightVector.Unit, pitchRad)):VectorToWorldSpace(baseDir)
	local dir = (pitchedDir + cf.RightVector * HIT_RIGHT_PIVOT).Unit
	return dir
end

local contactPart: BasePart? = tool:FindFirstChild("Contact") :: BasePart?

if not contactPart then
	warn("[Racket] Missing Contact part; hit redirect disabled.")
else
	contactPart.Touched:Connect(function(hit: BasePart)
		if not hit or not hit:IsA("BasePart") then return end
		if hit.CollisionGroup ~= "TennisBall" then return end

		-- Gate contact strictly to the active swing window
		if not isInSwingContactWindow() then return end

		if lastHitWasLocal(hit) then return end

		pcall(function()
			hit:SetAttribute("LastHitUserId", player.UserId)
		end)

		local dir = cameraHitDirection()
		local v0  = dir * currentPower

		local startPos   = hit.Position
		local ballRadius = math.max(hit.Size.X, hit.Size.Y, hit.Size.Z) * 0.5
		if ballRadius <= 0 then ballRadius = 0.25 end

		local baked = BallPhysics.Bake(startPos, v0, ballRadius, STEP_HZ)
		BallAnimator.PlayOnPart(hit, baked, { StartOffset = 0, DestroyOnStop = true })

		local ballId = hit:GetAttribute("BallId")
		if typeof(ballId) ~= "string" or #ballId == 0 then
			ballId = HttpService:GenerateGUID(false)
			pcall(function() hit:SetAttribute("BallId", ballId) end)
		end

		local payload = {
			ball = hit,
			part = hit,
			ballId = ballId,
			baked = baked,
			clientSentTime = Workspace:GetServerTimeNow(),
			lastHitUserId = player.UserId,
		}
		TrajEvent:FireServer(payload)

		playAndRelay("Impact")

		-- Reset power after each hit
		resetPowerToDefault()
	end)
end

----------------------------------------------------------------
-- Tool hooks
----------------------------------------------------------------

tool.Equipped:Connect(function()
	isEquipped = true
	enableShiftLock()
	loadTracks()
	task.wait(0.02)
	playIdle()

	resetPowerToDefault()

	if rightInputConn then rightInputConn:Disconnect(); rightInputConn = nil end
	rightInputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then return end
		if not isEquipped then return end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			playSwingOnce("backhand")
		end
	end)

	if wheelConn then wheelConn:Disconnect(); wheelConn = nil end
	wheelConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isEquipped then return end
		handleMouseWheel(input)
	end)
end)

tool.Unequipped:Connect(function()
	isEquipped = false
	teardownAndUnlock()
end)

tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		isEquipped = false
		teardownAndUnlock()
	end
end)

if (tool :: any).Destroying ~= nil then
	tool.Destroying:Connect(function()
		isEquipped = false
		teardownAndUnlock()
	end)
end

tool.Activated:Connect(function()
	playSwingOnce("forehand")
end)

player.CharacterAdded:Connect(function()
	isEquipped = (tool.Parent ~= nil and tool.Parent:IsA("Model") and tool.Parent:FindFirstChildOfClass("Humanoid") ~= nil)
	if not isEquipped then
		disableShiftLock()
		swingBusy = false
	else
		enableShiftLock()
		loadTracks()
		task.wait(0.02)
		playIdle()

		resetPowerToDefault()
		if wheelConn then wheelConn:Disconnect(); wheelConn = nil end
		wheelConn = UserInputService.InputChanged:Connect(function(input: InputObject)
			if not isEquipped then return end
			handleMouseWheel(input)
		end)
	end
end)
