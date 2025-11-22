--!nocheck
-- Receiver that WILL show it: forces C0 on remote rigs each frame, after animations.
-- If you still don't see it after this, the character isn't R15 or the joints don't exist.

------------------------- CONFIG -------------------------
local TOTAL_MAX_YAW_DEG = 100
local TORSO_MAX_YAW_DEG = 20
local HEAD_MAX_YAW_DEG  = 55

local TOTAL_MAX_PITCH_DEG = 90
local TORSO_MAX_PITCH_DEG = 35
local HEAD_MAX_PITCH_DEG  = 55

local SMOOTH_SPEED_YAW   = 18
local SMOOTH_SPEED_PITCH = 18
----------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer

local function radians(d:number) return d*math.pi/180 end
local TOTAL_MAX_YAW_RAD   = radians(TOTAL_MAX_YAW_DEG)
local TORSO_MAX_YAW_RAD   = radians(TORSO_MAX_YAW_DEG)
local HEAD_MAX_YAW_RAD    = radians(HEAD_MAX_YAW_DEG)
local TOTAL_MAX_PITCH_RAD = radians(TOTAL_MAX_PITCH_DEG)
local TORSO_MAX_PITCH_RAD = radians(TORSO_MAX_PITCH_DEG)
local HEAD_MAX_PITCH_RAD  = radians(HEAD_MAX_PITCH_DEG)

local function clamp(x,lo,hi) if x<lo then return lo elseif x>hi then return hi else return x end end

local function waitWaist(char:Model):Motor6D
	local ut = char:WaitForChild("UpperTorso") :: BasePart
	local lt = char:WaitForChild("LowerTorso") :: BasePart
	local w = ut:FindFirstChild("Waist")
	if w and w:IsA("Motor6D") then return w end
	for _,p in ipairs({ut,lt}) do
		for _,inst in ipairs(p:GetChildren()) do
			if inst:IsA("Motor6D") then
				local m = inst :: Motor6D
				if (m.Part0==lt and m.Part1==ut) or (m.Part0==ut and m.Part1==lt) then return m end
			end
		end
	end
	-- last resort: yield until found (handles rigs spawning slow)
	while true do
		task.wait()
		for _,p in ipairs({ut,lt}) do
			for _,inst in ipairs(p:GetChildren()) do
				if inst:IsA("Motor6D") then
					local m = inst :: Motor6D
					if (m.Part0==lt and m.Part1==ut) or (m.Part0==ut and m.Part1==lt) then return m end
				end
			end
		end
	end
end

local function waitNeck(char:Model):Motor6D
	local ut = char:WaitForChild("UpperTorso") :: BasePart
	local hd = char:WaitForChild("Head") :: BasePart
	local n = ut:FindFirstChild("Neck")
	if n and n:IsA("Motor6D") then return n end
	for _,p in ipairs({ut,hd}) do
		for _,inst in ipairs(p:GetChildren()) do
			if inst:IsA("Motor6D") then
				local m = inst :: Motor6D
				if (m.Part0==ut and m.Part1==hd) or (m.Part0==hd and m.Part1==ut) then return m end
			end
		end
	end
	while true do
		task.wait()
		for _,p in ipairs({ut,hd}) do
			for _,inst in ipairs(p:GetChildren()) do
				if inst:IsA("Motor6D") then
					local m = inst :: Motor6D
					if (m.Part0==ut and m.Part1==hd) or (m.Part0==hd and m.Part1==ut) then return m end
				end
			end
		end
	end
end

type Joints = { waist: Motor6D?, neck: Motor6D?, baseWaistC0: CFrame?, baseNeckC0: CFrame? }
type State = {
	char: Model?,
	j: Joints,
	curTorsoYaw: number, curHeadYaw: number,
	curTorsoPitch: number, curHeadPitch: number,
	targetYawTotal: number, targetPitchTotal: number,
}
local states: {[number]: State} = {}

local function hookPlayer(plr: Player)
	if plr == localPlayer then return end
	local function onChar(char:Model)
		-- hard wait for the actual joints; cache their base C0
		local waist = waitWaist(char)
		local neck  = waitNeck(char)
		states[plr.UserId] = {
			char = char,
			j = { waist=waist, neck=neck, baseWaistC0 = waist.C0, baseNeckC0 = neck.C0 },
			curTorsoYaw=0,curHeadYaw=0,curTorsoPitch=0,curHeadPitch=0,
			targetYawTotal=0,targetPitchTotal=0,
		}
	end
	plr.CharacterAdded:Connect(onChar)
	if plr.Character then onChar(plr.Character) end
end

for _,p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(function(p) states[p.UserId]=nil end)

local function smooth(cur, tgt, dt, speed) local a=1-math.exp(-speed*dt) return cur+(tgt-cur)*a end

local function applyAll(dt:number)
	for uid, st in pairs(states) do
		local char = st.char
		if not (char and char.Parent) then continue end

		local j = st.j
		if not (j.waist and j.neck) then
			-- in case joints showed up late, grab them now (non-yield)
			local c = Players:GetPlayerByUserId(uid)
			if c and c.Character then
				local ok = pcall(function()
					j.waist = char:FindFirstChild("UpperTorso") and waitWaist(char) or j.waist
					j.neck  = char:FindFirstChild("UpperTorso") and waitNeck(char)  or j.neck
				end)
				if ok and j.waist and not j.baseWaistC0 then j.baseWaistC0 = j.waist.C0 end
				if ok and j.neck  and not j.baseNeckC0  then j.baseNeckC0  = j.neck.C0  end
			end
			if not (j.waist and j.neck) then continue end
		end

		local totalYaw  = clamp(st.targetYawTotal,   -TOTAL_MAX_YAW_RAD,   TOTAL_MAX_YAW_RAD)
		local totalPit  = clamp(st.targetPitchTotal, -TOTAL_MAX_PITCH_RAD, TOTAL_MAX_PITCH_RAD)

		local halfYaw   = totalYaw*0.5
		local torsoYawT = clamp(halfYaw, -TORSO_MAX_YAW_RAD, TORSO_MAX_YAW_RAD)
		local headYawT  = clamp(totalYaw - torsoYawT, -HEAD_MAX_YAW_RAD, HEAD_MAX_YAW_RAD)

		local halfPit   = totalPit*0.5
		local torsoPitT = clamp(halfPit, -TORSO_MAX_PITCH_RAD, TORSO_MAX_PITCH_RAD)
		local headPitT  = clamp(totalPit - torsoPitT, -HEAD_MAX_PITCH_RAD, HEAD_MAX_PITCH_RAD)

		st.curTorsoYaw   = smooth(st.curTorsoYaw,   torsoYawT,  dt, SMOOTH_SPEED_YAW)
		st.curHeadYaw    = smooth(st.curHeadYaw,    headYawT,   dt, SMOOTH_SPEED_YAW)
		st.curTorsoPitch = smooth(st.curTorsoPitch, torsoPitT,  dt, SMOOTH_SPEED_PITCH)
		st.curHeadPitch  = smooth(st.curHeadPitch,  headPitT,   dt, SMOOTH_SPEED_PITCH)

		-- FORCE C0 override every frame, after anims
		local baseW = j.baseWaistC0 or j.waist.C0
		local baseN = j.baseNeckC0  or j.neck.C0
		j.waist.C0 = baseW * CFrame.Angles(0, st.curTorsoYaw, 0) * CFrame.Angles(st.curTorsoPitch, 0, 0)
		j.neck.C0  = baseN * CFrame.Angles(0, st.curHeadYaw,  0) * CFrame.Angles(st.curHeadPitch, 0, 0)
	end
end

-- Listen for payloads
local evt = ReplicatedStorage:WaitForChild("MiscEvents"):WaitForChild("CharRotation") :: RemoteEvent
evt.OnClientEvent:Connect(function(senderUserId:number, yaw:number, pitch:number)
	--print(senderUserId, yaw, pitch)
	if senderUserId == localPlayer.UserId then return end
	local st = states[senderUserId]
	if not st then
		local plr = Players:GetPlayerByUserId(senderUserId)
		if not plr then return end
		st = {
			char = plr.Character,
			j = { waist=nil, neck=nil, baseWaistC0=nil, baseNeckC0=nil },
			curTorsoYaw=0,curHeadYaw=0,curTorsoPitch=0,curHeadPitch=0,
			targetYawTotal=0,targetPitchTotal=0,
		}
		states[senderUserId] = st
	end
	st.targetYawTotal   = clamp(yaw,   -TOTAL_MAX_YAW_RAD,   TOTAL_MAX_YAW_RAD)
	st.targetPitchTotal = clamp(pitch, -TOTAL_MAX_PITCH_RAD, TOTAL_MAX_PITCH_RAD)
end)

-- Apply AFTER animations so we win the last write.
RunService:BindToRenderStep("RemoteLook_ApplyLast", Enum.RenderPriority.Last.Value, applyAll)
