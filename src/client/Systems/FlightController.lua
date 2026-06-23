--[[
	FlightController
	Owner of: the craft's sim State, its attitude (orientation), the active body,
	and flight status. Drives the master per-frame loop.

	Attitude is a real rigid-body rotation (_omega = angular velocity, integrated
	from torques against the craft's moment of inertia): control torque from weak
	reaction wheels + engine gimbal (WASD/QE, or SAS modes 1-5) and AERODYNAMIC
	torque from drag at the centre of pressure -- so an unstable rocket weathervanes
	or flips for real. Thrust fires along the nose (attitude.LookVector). Engine off
	coasts (propagate, warp-scaled, vacuum only); in air or under thrust it integrates
	(real dt) gravity + thrust + drag, burning fuel.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))
local Planet = require(Shared:WaitForChild("Planet"))

local FlightController = {}

local function unit(v)
	local m = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if m < 1e-9 then
		return nil
	end
	return Orbit.vec(v.x / m, v.y / m, v.z / m)
end

local function vadd(a, b)
	return Orbit.vec(a.x + b.x, a.y + b.y, a.z + b.z)
end
local function vsub(a, b)
	return Orbit.vec(a.x - b.x, a.y - b.y, a.z - b.z)
end
local function vlen(a)
	return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

function FlightController:Init()
	local body = Config.BODY
	-- The active central body switches with the SOI (patched conics). Sim state is kept
	-- RELATIVE to the active body; absolute (Terra-centric) positions are reconstructed
	-- by adding the active body's centre.
	self._planetMu = body.mu
	self._planetRadius = body.radius
	self._mu = body.mu
	self._bodyRadius = body.radius
	self._bodyId = "planet"
	self._bodyName = body.name
	self._missionTime = 0

	local m = Config.MOON
	self._moon = {
		name = m.name,
		mu = m.mu,
		radius = m.radius,
		orbitRadius = m.orbitRadius,
		color = m.color,
		phase = m.phase or 0,
		w = math.sqrt(body.mu / (m.orbitRadius * m.orbitRadius * m.orbitRadius)),
		soi = m.orbitRadius * (m.mu / body.mu) ^ (2 / 5),
	}

	self._turnStart = Config.LAUNCH.turnStartAlt
	self._turnEnd = Config.LAUNCH.turnEndAlt
	-- Launch site on the equator (unit direction), sitting on the terrain height there.
	local site = Config.LAUNCH.site
	self._launchDir = site.Unit
	local ld = self._launchDir
	self._launchRadius = Planet.radiusForSim(Orbit.vec(ld.X * body.radius, ld.Y * body.radius, ld.Z * body.radius))

	-- Nose points radial-out (along the launch direction).
	self._state = {
		position = Orbit.vec(ld.X * self._launchRadius, ld.Y * self._launchRadius, ld.Z * self._launchRadius),
		velocity = Orbit.vec(0, 0, 0),
	}
	self._attitude = self:_launchAttitude()
	self._omega = Vector3.zero -- angular velocity (world frame, rad/s)
	self._status = "VAB"
	self._powered = false
	self._landed = true
	self._crashed = false
	self._updateCount = 0
	self.Updated = Signal.new()
end

function FlightController:Start()
	self._input = Registry:Get("InputController")
	self._origin = Registry:Get("FloatingOriginController")
	self._mode = Registry:Get("GameModeController")
	self._vehicle = Registry:Get("VehicleController")

	self._mode.ModeChanged:Connect(function(m)
		self:_onMode(m)
	end)
	-- "Back to launch site" while already flying: reset the craft on the pad.
	self._mode.LaunchReset:Connect(function()
		self:_onMode("Flight")
	end)
	self._input:GetStageSignal():Connect(function()
		if self._mode:GetMode() ~= "Flight" then
			return
		end
		local droppedHeight = self._vehicle:Stage()
		-- The spent stage stays where it was; shift the (now shorter) craft up along
		-- its nose by the dropped height so the upper stage doesn't jump downward.
		if droppedHeight and droppedHeight > 0 then
			local n = self._attitude.LookVector
			local p = self._state.position
			self._state.position = Orbit.vec(p.x + n.X * droppedHeight, p.y + n.Y * droppedHeight, p.z + n.Z * droppedHeight)
		end
	end)

	self:_onMode(self._mode:GetMode())

	RunService:BindToRenderStep("RocketSim_Flight", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
end

-- Attitude on the pad: nose points radial-out along the launch direction.
function FlightController:_launchAttitude()
	local ld = self._launchDir
	local nose = Vector3.new(ld.X, ld.Y, ld.Z)
	local ref = (math.abs(nose.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	return CFrame.lookAt(Vector3.zero, nose, ref)
end

function FlightController:_onMode(mode)
	self._vehicle:ResetRuntime()
	-- Back on the pad: reset to Terra (the active body), at the equatorial launch site.
	self._bodyId = "planet"
	self._mu = self._planetMu
	self._bodyRadius = self._planetRadius
	self._bodyName = Config.BODY.name
	self._missionTime = 0
	local ld = self._launchDir
	self._state = {
		position = Orbit.vec(ld.X * self._launchRadius, ld.Y * self._launchRadius, ld.Z * self._launchRadius),
		velocity = Orbit.vec(0, 0, 0),
	}
	self._attitude = self:_launchAttitude()
	self._omega = Vector3.zero
	self._landed = true
	self._crashed = false
	self._status = (mode == "Flight") and "Landed" or "VAB"
	self._origin:SetOrigin(Orbit.vec(0, 0, 0))
end

-- The moon's Terra-centric state (position, velocity) at mission time t. It orbits in
-- the X/Z equatorial plane, coplanar with the equatorial launch.
function FlightController:_moonStateAt(t)
	local m = self._moon
	local a = m.phase + m.w * t
	local ca, sa = math.cos(a), math.sin(a)
	local r = m.orbitRadius
	return Orbit.vec(r * ca, 0, r * sa), Orbit.vec(-r * m.w * sa, 0, r * m.w * ca)
end

-- Terra-centric centre / velocity of the active body (zero for Terra itself).
function FlightController:_bodyCenter()
	if self._bodyId == "moon" then
		local p = self:_moonStateAt(self._missionTime)
		return p
	end
	return Orbit.vec(0, 0, 0)
end
function FlightController:_bodyVel()
	if self._bodyId == "moon" then
		local _, v = self:_moonStateAt(self._missionTime)
		return v
	end
	return Orbit.vec(0, 0, 0)
end

-- Patched conics: hop the sim state between Terra's frame and the moon's frame as the
-- craft crosses the moon's sphere of influence.
function FlightController:_checkSOI()
	if self._bodyId == "planet" then
		local mpos, mvel = self:_moonStateAt(self._missionTime)
		local rel = vsub(self._state.position, mpos) -- planet-frame: state IS Terra-centric
		if vlen(rel) < self._moon.soi then
			self._state = { position = rel, velocity = vsub(self._state.velocity, mvel) }
			self._bodyId = "moon"
			self._mu = self._moon.mu
			self._bodyRadius = self._moon.radius
			self._bodyName = self._moon.name
			self._landed = false
		end
	elseif vlen(self._state.position) > self._moon.soi then
		local mpos, mvel = self:_moonStateAt(self._missionTime)
		self._state = { position = vadd(self._state.position, mpos), velocity = vadd(self._state.velocity, mvel) }
		self._bodyId = "planet"
		self._mu = self._planetMu
		self._bodyRadius = self._planetRadius
		self._bodyName = Config.BODY.name
		self._landed = false
	end
end

function FlightController:_ascentDirection(pos)
	local rad = unit(pos)
	if not rad then
		return nil
	end
	local r = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	local alt = r - self._bodyRadius
	local f = math.clamp((alt - self._turnStart) / (self._turnEnd - self._turnStart), 0, 1)
	local tang = unit(Orbit.vec(-rad.z, 0, rad.x)) or Orbit.vec(0, 0, 1)
	return unit(Orbit.vec(
		rad.x * (1 - f) + tang.x * f,
		rad.y * (1 - f) + tang.y * f,
		rad.z * (1 - f) + tang.z * f
	)) or rad
end

local function v3(d)
	return d and Vector3.new(d.x, d.y, d.z) or nil
end

function FlightController:_sasTarget(sas, pos, vel)
	if sas == "Prograde" then
		return v3(unit(vel) or unit(pos))
	elseif sas == "Retrograde" then
		local d = unit(vel) or unit(pos)
		return d and Vector3.new(-d.x, -d.y, -d.z) or nil
	elseif sas == "RadialOut" then
		return v3(unit(pos))
	elseif sas == "RadialIn" then
		local d = unit(pos)
		return d and Vector3.new(-d.x, -d.y, -d.z) or nil
	elseif sas == "Ascent" then
		return v3(self:_ascentDirection(pos))
	end
	return nil
end

-- Rigid-body attitude: integrate angular velocity (self._omega) under control torque
-- (reaction wheels + engine gimbal) and aerodynamic torque (drag at the centre of
-- pressure about the centre of mass), then rotate the attitude by it. Returns the
-- active SAS mode for display.
function FlightController:_updateRotation(dt, pos, vel, powered, throttle)
	local C = Config.CONTROL
	local prof = self._vehicle:GetRotProfile()
	local I = prof.inertia

	local pitch, yaw, roll = self._input:GetAttitudeInput() -- may switch SAS to Manual
	local sas = self._input:GetSAS()

	local right = self._attitude.RightVector
	local up = self._attitude.UpVector
	local look = self._attitude.LookVector

	-- Control authority (rad/s^2): weak reaction wheels, plus gimbal while burning.
	local authority = C.reactionWheelAccel + (powered and (C.gimbalAccel * throttle) or 0)

	local accel = Vector3.zero
	if sas == "Manual" then
		-- Direct stick torque about the body axes (pitch/yaw/roll).
		accel = (right * pitch + up * yaw - look * roll) * authority
	else
		local target = self:_sasTarget(sas, pos, vel)
		if target and target.Magnitude > 1e-3 then
			-- PD toward the marker direction: stiffness * error-axis - rate damping.
			local tdir = target.Unit
			local errAxis = look:Cross(tdir) -- axis turning nose -> target, |.| = sin(err)
			if look:Dot(tdir) < 0 and errAxis.Magnitude < 0.05 then
				errAxis = up -- pointing ~180 deg away: pick any perpendicular to start the turn
			end
			accel = errAxis * C.sasKp - self._omega * C.sasKd
			if accel.Magnitude > authority then
				accel = accel.Unit * authority
			end
		end
	end

	-- Aerodynamic torque: drag acts at the centre of pressure, offset from the centre
	-- of mass along the nose. Behind CoM (margin > 0) -> weathervanes prograde; ahead
	-- -> flips. Plus passive air damping that grows with density.
	local A = Config.ATMOSPHERE
	local r = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	local alt = r - self._bodyRadius
	if self._bodyId == "planet" and alt < A.top then
		local rho = math.exp(-math.max(alt, 0) / A.scaleHeight)
		local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
		if speed > 1e-3 then
			local vdir = Vector3.new(vel.x, vel.y, vel.z) / speed
			local fMag = A.dragCoeff * self._vehicle:GetDragArea() * rho * speed * speed -- aero force
			local fDrag = vdir * (-fMag)
			local rCoP = look * (prof.cop - prof.com) -- CoM -> CoP, along the nose
			local torque = rCoP:Cross(fDrag)
			accel += torque * (A.momentScale / I)
		end
		accel -= self._omega * (C.aeroDamp * rho) -- passive pitch damping
	end

	-- Off-centre thrust: each firing engine pushes along the nose from its own lateral
	-- position, so an asymmetric engine layout (a lone side booster, an empty booster
	-- still attached) torques the craft about the centre of mass.
	if powered and throttle > 0 then
		local cx, cz = prof.comX or 0, prof.comZ or 0
		local tx, tz = 0, 0
		for _, e in ipairs(self._vehicle:GetActiveEngines()) do
			local dx, dz = e.x - cx, e.z - cz
			local f = e.thrust * throttle
			tx += -dz * f -- torque about the body right axis (pitch)
			tz += dx * f -- torque about the body up axis (yaw)
		end
		if tx ~= 0 or tz ~= 0 then
			accel += (right * tx + up * tz) * (C.thrustTorqueScale / I)
		end
	end

	local omega = self._omega + accel * dt
	if omega.Magnitude > C.maxOmega then
		omega = omega.Unit * C.maxOmega
	end
	self._omega = omega

	local w = omega.Magnitude
	if w > 1e-6 then
		self._attitude = CFrame.fromAxisAngle(omega / w, w * dt) * self._attitude
	end
	return sas
end

-- Map is drawn TO SCALE: the body radius maps to a fixed render size, so the
-- surface circle is exactly where it really is relative to the orbit (an orbit
-- that clears the drawn planet clears the real surface). Returns scale + the
-- render extent the map camera should frame.
function FlightController:_mapInfo()
	-- Compress the whole body+orbit to a fixed render size near the origin so it
	-- always fits on screen and renders, regardless of how large the orbit is.
	-- Returns (scale, frameRenderSize): everything is drawn at *scale, framed to size.
	local p = self._state.position
	local rNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local ro = Orbit.getReadout(self._state, self._mu)
	local apoR = (ro.apoapsis < math.huge) and ro.apoapsis or rNow
	local frameR = math.max(apoR, rNow, self._bodyRadius * 1.3)
	local frame = Config.MAP.frameSize
	return frame / frameR, frame
end

function FlightController:_fire(extra)
	extra.mode = self._mode:GetMode()
	extra.nose = self._attitude.LookVector
	extra.attitude = self._attitude
	extra.mapMode = self._input:GetMapMode()
	local mapScale, mapFrame = self:_mapInfo()
	extra.mapScale = mapScale
	extra.mapFrameRadius = mapFrame
	extra.mu = self._mu
	extra.bodyRadius = self._bodyRadius
	-- Patched-conic context: the active body's Terra-centric centre/velocity (so the
	-- renderer/camera can place the relative state in the world) and the moon's state
	-- (so the map can show it).
	extra.bodyId = self._bodyId
	extra.bodyName = self._bodyName
	extra.bodyCenter = self:_bodyCenter()
	extra.bodyVel = self:_bodyVel()
	local mpos = self:_moonStateAt(self._missionTime)
	extra.moonCenter = mpos
	extra.moonRadius = self._moon.radius
	extra.moonSoi = self._moon.soi
	extra.moonColor = self._moon.color
	self.Updated:Fire(self._state, extra)
end

function FlightController:_step(rawDt)
	local mode = self._mode:GetMode()
	local pos = self._state.position
	self._updateCount += 1

	if mode ~= "Flight" then
		self._status = "VAB"
		self._origin:UpdateFor(pos)
		self:_fire({ pointDir = self._attitude.LookVector, throttle = 0, powered = false, status = "VAB", warp = 1, sas = "VAB" })
		return
	end

	local dt = math.clamp(rawDt, 0, Config.FLIGHT.maxDt)

	-- Destroyed: the wreck is gone; hold here until the player relaunches (B / menu).
	if self._crashed then
		self._origin:UpdateFor(self._state.position)
		self:_fire({ pointDir = self._attitude.LookVector, throttle = 0, powered = false, status = "Crashed", warp = 1, sas = "--" })
		return
	end

	local throttle = self._input:GetThrottle()
	local warp = self._input:GetTimeWarp()

	local powered = false
	local sas

	-- Are we in air? (drag + reentry live here, and warp is pinned to 1x.)
	local A = Config.ATMOSPHERE
	local r0 = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	local inAtmo = (self._bodyId == "planet") and ((r0 - self._bodyRadius) < A.top)
	local effWarp = warp
	local reentry = 0

	if self._landed and throttle <= 0 then
		self._status = "Landed"
		self._omega = Vector3.zero -- sitting on the pad: no tumble
		sas = self._input:GetSAS()
	else
		local thrustAccel = self._vehicle:GetThrustAccel(throttle)
		powered = throttle > 0 and thrustAccel > 0
		sas = self:_updateRotation(dt, pos, self._state.velocity, powered, throttle)
		local nose = self._attitude.LookVector

		if powered or inAtmo then
			-- Thrust and drag are not conic forces, so integrate numerically; this
			-- path also can't be time-warped.
			effWarp = 1
			if inAtmo and warp > 1 then
				self._input:ResetWarp()
			end
			local k = A.dragCoeff * (self._vehicle:GetDragArea() + self._vehicle:GetChuteDragArea()) / math.max(self._vehicle:GetCurrentMass(), 1e-3)
			self._state = Orbit.integrate(self._state, self._mu, dt, function(p2, v2)
				local ax, ay, az = 0, 0, 0
				if powered then
					ax, ay, az = nose.X * thrustAccel, nose.Y * thrustAccel, nose.Z * thrustAccel
				end
				local r2 = math.sqrt(p2.x * p2.x + p2.y * p2.y + p2.z * p2.z)
				local alt2 = r2 - self._bodyRadius
				if self._bodyId == "planet" and alt2 < A.top then
					-- a_drag = -k * densityFrac * |v| * v  (opposes velocity)
					local rho = math.exp(-math.max(alt2, 0) / A.scaleHeight)
					local speed = math.sqrt(v2.x * v2.x + v2.y * v2.y + v2.z * v2.z)
					-- Clamp the drag coefficient so a fully-deployed parachute (huge drag at
					-- speed) can't overshoot the integrator and fling the craft -- it just
					-- decelerates hard and smoothly. (|d|*dt <= 1 keeps RK4 stable.)
					local d = -math.min(k * rho * speed, 1 / math.max(dt, 1e-3))
					ax += v2.x * d
					ay += v2.y * d
					az += v2.z * d
				end
				return Orbit.vec(ax, ay, az)
			end)
			if powered then
				self._vehicle:ConsumeFuel(dt, throttle)
			end
		else
			self._state = Orbit.propagate(self._state, self._mu, dt * warp)
		end

		self:_checkTouchdown() -- rest on terrain, or destroy if too fast
		if not self._landed then
			self._status = powered and "Powered" or "Coasting"
		end

		-- Reentry heating intensity from dynamic pressure (densityFrac * speed^2).
		if inAtmo and not self._landed then
			local v = self._state.velocity
			local p = self._state.position
			local altNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - self._bodyRadius
			local rho = math.exp(-math.max(altNow, 0) / A.scaleHeight)
			local q = rho * (v.x * v.x + v.y * v.y + v.z * v.z)
			reentry = math.clamp((q - A.reentryQ) / (A.maxReentryQ - A.reentryQ), 0, 1)
		end
	end

	-- Advance mission time (the moon orbits on rails) and hop SOIs if we crossed one.
	self._missionTime += dt * effWarp
	self:_checkSOI()

	self._powered = powered
	self._origin:UpdateFor(vadd(self._state.position, self:_bodyCenter()))
	local nose = self._attitude.LookVector
	self:_fire({
		pointDir = nose,
		dt = dt,
		throttle = throttle,
		warp = effWarp,
		sas = sas,
		powered = powered,
		status = self._status,
		inAtmo = inAtmo,
		reentry = reentry,
		chuteDeployed = inAtmo and self._vehicle:HasDeployedChute(),
		tele = self._vehicle:GetTelemetry(throttle),
	})
end

-- Whole-body terrain collision: sample the entire rocket (base -> nose), so ANY
-- part touching the ground counts (a sideways/tumbling craft hits on its side, not
-- just the engine). If the deepest point has reached the terrain, rest the craft on
-- it (slow) or destroy it (impact faster than the crash speed).
function FlightController:_checkTouchdown()
	local p = self._state.position
	local nose = self._attitude.LookVector -- base -> nose, unit
	local len = self._vehicle:GetRotProfile().length

	-- On the moon there is no terrain heightfield: the surface is a smooth sphere.
	local onMoon = (self._bodyId == "moon")
	local moonR = self._moon.radius

	local maxPen = 0
	local s = 0
	while s <= len + 1e-3 do
		local wx, wy, wz = p.x + nose.X * s, p.y + nose.Y * s, p.z + nose.Z * s
		local wr = math.sqrt(wx * wx + wy * wy + wz * wz)
		if wr > 1e-6 then
			local surf = onMoon and moonR or Planet.radiusForUnit(wx / wr, wy / wr, wz / wr)
			local pen = surf - wr
			if pen > maxPen then
				maxPen = pen
			end
		end
		s += 2 -- sample every ~2 studs along the body
	end

	if maxPen <= 0 then
		self._landed = false
		return
	end

	local vel = self._state.velocity
	local impact = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)

	-- Lift the craft out along the radial so the deepest point clears the surface.
	local up = unit(p) or Orbit.vec(0, 1, 0)
	self._state.position = Orbit.vec(p.x + up.x * maxPen, p.y + up.y * maxPen, p.z + up.z * maxPen)
	self._state.velocity = Orbit.vec(0, 0, 0)
	self._landed = true

	-- Landing legs roughly double the survivable touchdown speed.
	local crashSpeed = Config.FLIGHT.crashSpeed * (self._vehicle:HasLandingLegs() and 2 or 1)
	if impact > crashSpeed then
		self._crashed = true -- too fast: the renderer blows the whole rocket apart
		self._status = "Crashed"
	else
		self._crashed = false
		self._status = "Landed"
	end
end

function FlightController:GetState()
	return self._state
end
function FlightController:GetMu()
	return self._mu
end
function FlightController:GetBodyRadius()
	return self._bodyRadius
end
-- The moon's current Terra-centric position (for MoonRenderer) and its size.
function FlightController:GetMoonCenter()
	local p = self:_moonStateAt(self._missionTime)
	return p
end
function FlightController:GetMoonRadius()
	return self._moon.radius
end
-- Sim position of the launch pad base (the VAB build origin; nose points radial-out here).
function FlightController:GetLaunchPosition()
	local ld = self._launchDir
	return Orbit.vec(ld.X * self._launchRadius, ld.Y * self._launchRadius, ld.Z * self._launchRadius)
end
-- The launch radial-out direction (build-space +Y maps to this in the world).
function FlightController:GetLaunchUp()
	return self._launchDir
end
function FlightController:GetUpdatedSignal()
	return self.Updated
end
function FlightController:GetUpdateCount()
	return self._updateCount
end
function FlightController:GetReadout()
	return Orbit.getReadout(self._state, self._mu, self._bodyRadius)
end

return FlightController
