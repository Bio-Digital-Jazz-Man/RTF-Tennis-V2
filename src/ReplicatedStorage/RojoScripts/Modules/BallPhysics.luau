-- BallTrajectory.lua
-- Deterministic tennis ball trajectory solver with CCD (court/net/netTip/walls) and rolling.
-- Hard safety cutoffs: Y_MIN/Y_MAX bounds and MAX_ARC_TIME per airborne arc.
-- Pure bake + sample. No networking, no visuals, no rally logic.
-- Includes anti-stall guards and an explicit toggle for retaining impact BasePart refs.

local Workspace  = game:GetService("Workspace")

-- ===== PHYSICS (tuning) =====
local G                    = 35.0
local RESTITUTION          = 0.80
local TANGENTIAL_LOSS      = 0.985
local IMPACT_GLOBAL_LOSS   = 0.90
local MIN_APEX             = 2

local AIR_DRAG             = 0.99775
local ROLL_FRICTION        = 0.970
local ROLL_LOCK_EPS        = 0.15

-- Net (standard)
local NET_DAMPING          = 0.20
local NET_PAD              = 0.01

-- NetTip (light touch: ~15% drag)
local NET_TIP_DRAG_MULT    = 0.85
local NET_TIP_PAD          = 0.005

-- Walls
local WALL_RESTITUTION     = 0.80
local WALL_TANGENTIAL_LOSS = 0.985
local WALL_DAMPING         = 0.95
local WALL_PAD             = 0.005

-- ===== SAFETY LIMITS (hard cutoffs) =====
local Y_MIN                = -10.0   -- below this: cull and stop
local Y_MAX                =  300.0  -- above this: cull and stop
local MAX_ARC_TIME         =  10.0   -- max time for any airborne arc segment
local MAX_SOLVES_PER_DT    = 10
local SIM_FAILSAFE_SAMPLES = 2_000_000 -- prevents infinite loops

-- Anti-stall / anti-churn (prevents “zero-time” loops that can bloat memory very rarely)
local EPS_T                = 1e-5      -- minimum time we’ll consume on any impact advance
local MAX_NO_PROGRESS_FR   = 8         -- if wall-clock simulation time doesn't advance for this many outer ticks, bail

-- ===== DEFAULTS =====
local DEFAULT_BALL_RADIUS  = 0.25
local DEFAULT_STEP_HZ      = 120

-- ---------- helpers ----------
local function partsInGroup(groupName: string): {Instance}
	local out = {}
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("BasePart") and inst.CollisionGroup == groupName then
			table.insert(out, inst)
		end
	end
	return out
end

local function rayWhitelist(origin: Vector3, direction: Vector3, whitelist: {Instance})
	if #whitelist == 0 then return nil end
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Whitelist
	p.FilterDescendantsInstances = whitelist
	return Workspace:Raycast(origin, direction, p)
end

local function sphereSweep(origin: Vector3, seg: Vector3, radius: number, whitelist: {Instance})
	if #whitelist == 0 then return nil, nil end
	local len = seg.Magnitude
	if len < 1e-6 then return nil, nil end
	local dir = seg / len
	local hit = rayWhitelist(origin, dir * (len + radius), whitelist)
	if not hit then return nil, nil end
	local dist = (hit.Position - origin).Magnitude
	local t = math.clamp((dist - radius) / len, 0, 1)
	return hit, t
end

local function solveCourtTOI(y0: number, vy0: number, r: number, courtY: number, dt: number)
	local a = -0.5 * G
	local b = vy0
	local c = (y0 - r) - courtY
	if c <= 0 and vy0 <= 0 then return 0 end
	if vy0 < 0 or (vy0 - G * dt) < 0 then
		local D = b*b - 4*a*c
		if D >= 0 then
			local s = math.sqrt(D)
			local t1 = (-b - s) / (2*a)
			local t2 = (-b + s) / (2*a)
			local tHit = math.huge
			if t1 >= 0 and t1 <= dt then tHit = t1 end
			if t2 >= 0 and t2 <= dt then tHit = math.min(tHit, t2) end
			if tHit ~= math.huge then return tHit end
		end
	end
	return nil
end

-- ===== Module =====
local BallTrajectory = {}

export type BakedSample = { t:number, p:Vector3, v:Vector3, state:number, event:string? }
export type BakedImpact = { t:number, kind:string, pos:Vector3, state:number, hit: BasePart? }
export type BakedPath   = { stepHz:number, radius:number, samples:{BakedSample}, totalTime:number, impacts:{BakedImpact} }

BallTrajectory.DefaultStepHz     = DEFAULT_STEP_HZ
BallTrajectory.DefaultBallRadius = DEFAULT_BALL_RADIUS

-- IMPORTANT: keep BasePart refs in impacts so debug visuals can flash the exact part.
-- Toggle this to false ONLY in production if you find paths are retained too long by your code.
BallTrajectory.KeepHitRefs = true

-- ===== Core bake (pure trajectory) =====
function BallTrajectory.Bake(startPos: Vector3, initialVelocity: Vector3, radius: number?, stepHz: number?): BakedPath
	local r  = radius or DEFAULT_BALL_RADIUS
	local hz = math.max(30, stepHz or DEFAULT_STEP_HZ)
	local dtFixed = 1.0 / hz

	-- Cache geometry ONCE per bake
	local court  = partsInGroup("CourtGround")
	local net    = partsInGroup("Net")
	local netTip = partsInGroup("NetTip")
	local walls  = partsInGroup("CourtWall")

	-- States
	local STATE_AIR, STATE_ROLL = 0, 1
	local state = STATE_AIR
	local p = startPos
	local v = initialVelocity
	local t = 0.0

	-- Arc timer for airborne segments (reset at each impact)
	local arcTime = 0.0

	local samples: {BakedSample} = {}
	local impacts: {BakedImpact} = {}

	table.insert(samples, { t = 0.0, p = p, v = v, state = state })

	local savedCount = 1
	local stopSim = false
	local noProgressFrames = 0

	while true do
		local tBefore = t

		-- Global failsafes
		if savedCount > SIM_FAILSAFE_SAMPLES then
			table.insert(samples, { t = t, p = p, v = v, state = state, event = "Stop" })
			break
		end
		if p.Y < Y_MIN or p.Y > Y_MAX then
			table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
			break
		end

		local tRemain = dtFixed
		local solves = 0

		-- ================= AIR (CCD vs court/net/tip/walls) =================
		if state == STATE_AIR and not stopSim then
			while tRemain > 1e-6 and solves < MAX_SOLVES_PER_DT do
				solves += 1
				v *= AIR_DRAG

				-- Sample ground beneath projected XZ
				local projXZ = p + Vector3.new(v.X * tRemain, 0, v.Z * tRemain)
				local courtSample = rayWhitelist(projXZ + Vector3.new(0,1000,0), Vector3.new(0,-5000,0), court)
				local courtY = courtSample and courtSample.Position.Y or nil
				local nCourt = courtSample and courtSample.Normal or Vector3.yAxis

				local vy0 = v.Y
				local tCourt = courtY and solveCourtTOI(p.Y, vy0, r, courtY, tRemain) or nil

				local seg = v * tRemain
				local netHit,  tNetFrac  = sphereSweep(p, seg, r, net)
				local tipHit,  tTipFrac  = sphereSweep(p, seg, r, netTip)
				local wallHit, tWallFrac = sphereSweep(p, seg, r, walls)

				-- arc time cap before advancing
				if arcTime >= MAX_ARC_TIME then
					table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
					stopSim = true
					break
				end

				local mode: string? = nil
				local tImpact: number? = nil

				if tCourt or netHit or tipHit or wallHit then
					local candidate = math.huge
					if tCourt and tCourt <= candidate then
						candidate = tCourt; mode = "Court"; tImpact = tCourt
					end
					if netHit then
						local tn = tNetFrac * tRemain
						if tn <= candidate then candidate = tn; mode = "Net"; tImpact = tn end
					end
					if tipHit then
						local tt = tTipFrac * tRemain
						if tt <= candidate then candidate = tt; mode = "NetTip"; tImpact = tt end
					end
					if wallHit then
						local tw = tWallFrac * tRemain
						if tw <= candidate then candidate = tw; mode = "Wall"; tImpact = tw end
					end
				end

				if not mode or not tImpact then
					local tStep = tRemain
					if arcTime + tStep > MAX_ARC_TIME then
						tStep = math.max(0, MAX_ARC_TIME - arcTime)
					end
					if tStep <= 0 then
						tStep = math.min(EPS_T, tRemain)
					end

					p = Vector3.new(p.X + v.X * tStep, p.Y + vy0 * tStep - 0.5 * G * tStep * tStep, p.Z + v.Z * tStep)
					v = Vector3.new(v.X, vy0 - G * tStep, v.Z)
					t += tStep
					arcTime += tStep
					tRemain -= tStep

					if p.Y < Y_MIN or p.Y > Y_MAX then
						table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
						stopSim = true
						break
					end
					if arcTime >= MAX_ARC_TIME then
						table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
						stopSim = true
						break
					end
					break
				end

				local tHitRaw = math.max(0, math.min(tImpact, tRemain))
				local tHit = tHitRaw
				if tHit <= 0 then
					tHit = math.min(EPS_T, tRemain)
				end
				if arcTime + tHit > MAX_ARC_TIME then
					local tCut = math.max(0, MAX_ARC_TIME - arcTime)
					if tCut <= 0 then tCut = math.min(EPS_T, tRemain) end
					p = Vector3.new(p.X + v.X * tCut, p.Y + vy0 * tCut - 0.5 * G * tCut * tCut, p.Z + v.Z * tCut)
					v = Vector3.new(v.X, vy0 - G * tCut, v.Z)
					t += tCut
					arcTime = arcTime + tCut
					table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
					stopSim = true
					break
				end

				local pAt = Vector3.new(p.X + v.X * tHit, p.Y + vy0 * tHit - 0.5 * G * tHit * tHit, p.Z + v.Z * tHit)
				local vAt = Vector3.new(v.X, vy0 - G * tHit, v.Z)

				if mode == "Court" then
					p = pAt + nCourt * r
					local vnMag = vAt:Dot(nCourt)
					local vn    = nCourt * vnMag
					local vt    = vAt - vn

					local vnp   = RESTITUTION * math.abs(vnMag)
					local apex  = (vnp * vnp) / (2 * G)

					t += tHit
					if apex < MIN_APEX then
						v = Vector3.new(vt.X * TANGENTIAL_LOSS, 0, vt.Z * TANGENTIAL_LOSS)
						table.insert(impacts, { t = t, kind = "Court", pos = p, state = STATE_ROLL, hit = courtSample and courtSample.Instance or nil })
						arcTime = 0.0
						tRemain -= tHit
						table.insert(samples, { t = t, p = p, v = v, state = STATE_ROLL, event = "Court" })
						state = STATE_ROLL
						break
					else
						local vnRef = -RESTITUTION * vn
						v = (vt * TANGENTIAL_LOSS) + vnRef
						v = v * IMPACT_GLOBAL_LOSS
						arcTime = 0.0
						tRemain -= tHit
						table.insert(impacts, { t = t, kind = "Court", pos = p, state = STATE_AIR, hit = courtSample and courtSample.Instance or nil })
						table.insert(samples, { t = t, p = p, v = v, state = STATE_AIR, event = "Court" })
						if tRemain > 0 then
							local vy1 = v.Y
							local tStep = tRemain
							if arcTime + tStep > MAX_ARC_TIME then
								tStep = math.max(0, MAX_ARC_TIME - arcTime)
							end
							if tStep <= 0 then tStep = math.min(EPS_T, tRemain) end
							p = Vector3.new(p.X + v.X * tStep, p.Y + vy1 * tStep - 0.5 * G * tStep * tStep, p.Z + v.Z * tStep)
							v = Vector3.new(v.X, vy1 - G * tStep, v.Z)
							t += tStep
							arcTime += tStep
							tRemain -= tStep
						end
					end

				elseif mode == "Net" then
					local n = netHit and netHit.Normal or Vector3.zAxis
					p = pAt + n * NET_PAD
					v = vAt * NET_DAMPING
					local into = v:Dot(n); if into < 0 then v = v - into * n end
					t += tHit
					arcTime = 0.0
					tRemain -= tHit
					table.insert(impacts, { t = t, kind = "Net", pos = p, state = STATE_AIR, hit = netHit and netHit.Instance or nil })
					table.insert(samples, { t = t, p = p, v = v, state = STATE_AIR, event = "Net" })
					if tRemain > 0 then
						local vy1 = v.Y
						local tStep = tRemain
						if arcTime + tStep > MAX_ARC_TIME then
							tStep = math.max(0, MAX_ARC_TIME - arcTime)
						end
						if tStep <= 0 then tStep = math.min(EPS_T, tRemain) end
						p = Vector3.new(p.X + v.X * tStep, p.Y + vy1 * tStep - 0.5 * G * tStep * tStep, p.Z + v.Z * tStep)
						v = Vector3.new(v.X, vy1 - G * tStep, v.Z)
						t += tStep
						arcTime += tStep
						tRemain -= tStep
					end

				elseif mode == "NetTip" then
					local n = tipHit and tipHit.Normal or Vector3.zAxis
					p = pAt + n * NET_TIP_PAD
					local vNew = vAt * NET_TIP_DRAG_MULT
					local into = vNew:Dot(n)
					if into < 0 then vNew = vNew - into * n end
					v = vNew
					t += tHit
					arcTime = 0.0
					tRemain -= tHit
					table.insert(impacts, { t = t, kind = "NetTip", pos = p, state = STATE_AIR, hit = tipHit and tipHit.Instance or nil })
					table.insert(samples, { t = t, p = p, v = v, state = STATE_AIR, event = "NetTip" })
					if tRemain > 0 then
						local vy1 = v.Y
						local tStep = tRemain
						if arcTime + tStep > MAX_ARC_TIME then
							tStep = math.max(0, MAX_ARC_TIME - arcTime)
						end
						if tStep <= 0 then tStep = math.min(EPS_T, tRemain) end
						p = Vector3.new(p.X + v.X * tStep, p.Y + vy1 * tStep - 0.5 * G * tStep * tStep, p.Z + v.Z * tStep)
						v = Vector3.new(v.X, vy1 - G * tStep, v.Z)
						t += tStep
						arcTime += tStep
						tRemain -= tStep
					end

				else -- Wall
					local n = (wallHit and wallHit.Normal) or Vector3.xAxis
					p = pAt + n * WALL_PAD
					local vnMag = vAt:Dot(n)
					local vn    = n * vnMag
					local vt    = vAt - vn
					local vRef  = (-WALL_RESTITUTION * vn) + (WALL_TANGENTIAL_LOSS * vt)
					v = (vRef * IMPACT_GLOBAL_LOSS) * WALL_DAMPING
					local into = v:Dot(n); if into < 0 then v = v - into * n end

					t += tHit
					arcTime = 0.0
					tRemain -= tHit
					table.insert(impacts, { t = t, kind = "Wall", pos = p, state = STATE_AIR, hit = wallHit and wallHit.Instance or nil })
					table.insert(samples, { t = t, p = p, v = v, state = STATE_AIR, event = "Wall" })

					if tRemain > 0 then
						local vy1 = v.Y
						local tStep = tRemain
						if arcTime + tStep > MAX_ARC_TIME then
							tStep = math.max(0, MAX_ARC_TIME - arcTime)
						end
						if tStep <= 0 then tStep = math.min(EPS_T, tRemain) end
						p = Vector3.new(p.X + v.X * tStep, p.Y + vy1 * tStep - 0.5 * G * tStep * tStep, p.Z + v.Z * tStep)
						v = Vector3.new(v.X, vy1 - G * tStep, v.Z)
						t += tStep
						arcTime += tStep
						tRemain -= tStep
					end
				end

				if p.Y < Y_MIN or p.Y > Y_MAX then
					table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
					stopSim = true
					break
				end
			end
		end

		if stopSim then break end

		-- ================= ROLL (CCD vs walls/net/netTip) =================
		if state == STATE_ROLL then
			local function applyFriction(vxy: Vector3, dtStep: number): Vector3
				local m = math.pow(ROLL_FRICTION, dtStep * 60)
				return vxy * m
			end

			local tRemainRoll = dtFixed
			local solvesRoll = 0

			while tRemainRoll > 1e-6 and solvesRoll < MAX_SOLVES_PER_DT do
				solvesRoll += 1

				local vxy = Vector3.new(v.X, 0, v.Z)
				if vxy.Magnitude < 1e-6 then
					t += tRemainRoll
					tRemainRoll = 0
					break
				end

				local seg = vxy * tRemainRoll

				local hitWall, tw = sphereSweep(p, seg, r, walls)
				local hitNet,  tn = sphereSweep(p, seg, r, net)
				local hitTip,  tt = sphereSweep(p, seg, r, netTip)

				local mode: string? = nil
				local tFrac: number? = nil
				local nrm: Vector3? = nil
				local hitInstance: BasePart? = nil

				if hitWall or hitNet or hitTip then
					local candidate = math.huge
					if hitWall then
						local tsec = tw * tRemainRoll
						if tsec <= candidate then
							candidate = tsec; tFrac = tw; mode = "Wall"; nrm = hitWall.Normal; hitInstance = hitWall.Instance
						end
					end
					if hitNet then
						local tsec = tn * tRemainRoll
						if tsec <= candidate then
							candidate = tsec; tFrac = tn; mode = "Net"; nrm = hitNet.Normal; hitInstance = hitNet.Instance
						end
					end
					if hitTip then
						local tsec = tt * tRemainRoll
						if tsec <= candidate then
							candidate = tsec; tFrac = tt; mode = "NetTip"; nrm = hitTip.Normal; hitInstance = hitTip.Instance
						end
					end
				end

				if not mode or not tFrac then
					local step = tRemainRoll
					if step <= 0 then step = math.min(EPS_T, tRemainRoll) end
					p = p + vxy * step
					local res = rayWhitelist(p + Vector3.new(0,1000,0), Vector3.new(0,-5000,0), court)
					if res then p = Vector3.new(p.X, res.Position.Y + r, p.Z) end

					vxy = applyFriction(vxy, step)
					v = Vector3.new(vxy.X, 0, vxy.Z)
					t += step
					tRemainRoll -= step
					break
				end

				local tHitRaw = math.max(0, math.min(tFrac * tRemainRoll, tRemainRoll))
				local tHit = tHitRaw
				if tHit <= 0 then
					tHit = math.min(EPS_T, tRemainRoll)
				end
				local vxyPre = vxy
				local n = (nrm or Vector3.xAxis)

				p = p + vxyPre * tHit
				local res = rayWhitelist(p + Vector3.new(0,1000,0), Vector3.new(0,-5000,0), court)
				if res then p = Vector3.new(p.X, res.Position.Y + r, p.Z) end

				p = p + n * WALL_PAD

				local vnMag = vxyPre:Dot(n)
				local vn = n * vnMag
				local vt = vxyPre - vn
				local vRef = (-WALL_RESTITUTION * vn) + (WALL_TANGENTIAL_LOSS * vt)
				vRef = (vRef * IMPACT_GLOBAL_LOSS) * WALL_DAMPING
				local into = vRef:Dot(n); if into < 0 then vRef = vRef - into * n end

				local vAfter = vRef
				vAfter = Vector3.new(vAfter.X, 0, vAfter.Z)
				vAfter = Vector3.new(vAfter.X, 0, vAfter.Z) -- explicit

				v = Vector3.new((math.pow(ROLL_FRICTION, tHit * 60)) * vAfter.X, 0, (math.pow(ROLL_FRICTION, tHit * 60)) * vAfter.Z)

				t += tHit
				tRemainRoll -= tHit

				table.insert(impacts, { t = t, kind = mode, pos = p, state = STATE_ROLL, hit = hitInstance })
				table.insert(samples, { t = t, p = p, v = v, state = STATE_ROLL, event = mode })

				if v.Magnitude < 0.25 then
					tRemainRoll = 0
					break
				end
			end

			if p.Y < Y_MIN or p.Y > Y_MAX then
				table.insert(samples, { t = t, p = p, v = v, state = state, event = "Cull" })
				break
			end
		end

		table.insert(samples, { t = t, p = p, v = v, state = state })
		savedCount += 1

		if state == STATE_ROLL and v.Magnitude < 0.25 then
			table.insert(samples, { t = t, p = p, v = Vector3.zero, state = state, event = "Stop" })
			break
		end

		if t == tBefore then
			noProgressFrames += 1
			if noProgressFrames >= MAX_NO_PROGRESS_FR then
				table.insert(samples, { t = t, p = p, v = v, state = state, event = "Stuck" })
				break
			end
		else
			noProgressFrames = 0
		end
	end

	-- Only strip refs if you absolutely want to (e.g., to minimize retention in long-running sessions).
	if BallTrajectory.KeepHitRefs == false then
		for i = 1, #impacts do
			impacts[i].hit = nil
		end
	end

	return {
		stepHz    = hz,
		radius    = r,
		samples   = samples,
		totalTime = t,
		impacts   = impacts,
	}
end

-- Fast lookup of the baked sample at time t (ceil-to-sample semantics).
function BallTrajectory.SampleAtTime(baked: BakedPath, tt: number)
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

return BallTrajectory
