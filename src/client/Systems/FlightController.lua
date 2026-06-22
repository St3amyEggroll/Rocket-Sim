--[[
	FlightController
	Owner of: the craft's sim State, its attitude (orientation), the active body,
	and flight status. Drives the master per-frame loop.

	Attitude is manual (WASD/QE) or auto-oriented (SAS: 1-5). Thrust always fires
	along the nose (attitude.LookVector). VAB mode holds the craft on the pad;
	Flight mode lets it fly. Engine off coasts (propagate, warp-scaled); thrust on
	integrates (real dt) using the built rocket's thrust/mass, burning fuel.
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

function FlightController:Init()
	local body = Config.BODY
	self._mu = body.mu
	self._bodyRadius = body.radius
	self._turnStart = Config.LAUNCH.turnStartAlt
	self._turnEnd = Config.LAUNCH.turnEndAlt
	-- Launch site at the +Y pole, sitting on the terrain height there.
	self._launchRadius = Planet.radiusForSim(Orbit.vec(0, body.radius, 0))

	-- Nose points radial-out (+Y).
	self._state = { position = Orbit.vec(0, self._launchRadius, 0), velocity = Orbit.vec(0, 0, 0) }
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.yAxis, Vector3.xAxis)
	self._status = "VAB"
	self._powered = false
	self._landed = true
	self._crashed = false
	self._tipping = false
	self._tipProgress = 0
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
		if self._mode:GetMode() == "Flight" then
			self._vehicle:Stage()
		end
	end)

	self:_onMode(self._mode:GetMode())

	RunService:BindToRenderStep("RocketSim_Flight", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
end

function FlightController:_onMode(mode)
	self._vehicle:ResetRuntime()
	-- Stand on the legs at launch (the base rests standHeight above the pad).
	local stand = self._vehicle:HasLegs() and Config.LEGS.standHeight or 0
	self._state = { position = Orbit.vec(0, self._launchRadius + stand, 0), velocity = Orbit.vec(0, 0, 0) }
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.yAxis, Vector3.xAxis)
	self._landed = true
	self._crashed = false
	self._tipping = false
	self._tipProgress = 0
	self._status = (mode == "Flight") and "Landed" or "VAB"
	self._origin:SetOrigin(Orbit.vec(0, 0, 0))
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

function FlightController:_updateAttitude(dt, pos, vel)
	local pitch, yaw, roll = self._input:GetAttitudeInput() -- may switch SAS to Manual
	local sas = self._input:GetSAS()
	local C = Config.CONTROL

	if sas == "Manual" then
		self._attitude = self._attitude
			* CFrame.Angles(pitch * C.pitchRate * dt, yaw * C.yawRate * dt, roll * C.rollRate * dt)
	else
		local target = self:_sasTarget(sas, pos, vel)
		if target and target.Magnitude > 1e-3 then
			target = target.Unit
			local up = Vector3.new(pos.x, pos.y, pos.z)
			up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
			if math.abs(target:Dot(up)) > 0.99 then
				up = target:Cross(Vector3.xAxis)
				if up.Magnitude < 1e-3 then
					up = target:Cross(Vector3.zAxis)
				end
				up = up.Unit
			end
			local targetCF = CFrame.lookAt(Vector3.zero, target, up)
			self._attitude = self._attitude:Lerp(targetCF, math.clamp(C.sasSlew * dt, 0, 1))
		end
	end
	return sas
end

-- Map is drawn TO SCALE: the body radius maps to a fixed render size, so the
-- surface circle is exactly where it really is relative to the orbit (an orbit
-- that clears the drawn planet clears the real surface). Returns scale + the
-- render extent the map camera should frame.
function FlightController:_mapInfo()
	-- Small world: map is drawn at TRUE scale around the real terrain planet.
	local p = self._state.position
	local rNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local ro = Orbit.getReadout(self._state, self._mu)
	local apoR = (ro.apoapsis < math.huge) and ro.apoapsis or rNow
	local frameRender = math.max(apoR, rNow, self._bodyRadius * 1.3)
	return 1, frameRender
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

	-- Tipping over after a bad landing (scripted): rotate the craft onto its side.
	if self._tipping then
		self:_advanceTip(dt)
		self._origin:UpdateFor(self._state.position)
		self:_fire({ pointDir = self._attitude.LookVector, throttle = 0, powered = false, status = "Crashed", warp = 1, sas = "--" })
		return
	end
	-- Crashed wreck: hold it until the player rebuilds / relaunches (B).
	if self._crashed then
		self._origin:UpdateFor(self._state.position)
		self:_fire({ pointDir = self._attitude.LookVector, throttle = 0, powered = false, status = "Crashed", warp = 1, sas = "--" })
		return
	end

	local throttle = self._input:GetThrottle()
	local warp = self._input:GetTimeWarp()

	local sas = self:_updateAttitude(dt, pos, self._state.velocity)
	local nose = self._attitude.LookVector
	local powered = false

	-- Are we in air? (drag + reentry live here, and warp is pinned to 1x.)
	local A = Config.ATMOSPHERE
	local r0 = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	local inAtmo = (r0 - self._bodyRadius) < A.top
	local effWarp = warp
	local reentry = 0

	if self._landed and throttle <= 0 then
		self._status = "Landed"
	else
		local thrustAccel = self._vehicle:GetThrustAccel(throttle)
		powered = throttle > 0 and thrustAccel > 0

		if powered or inAtmo then
			-- Thrust and drag are not conic forces, so integrate numerically; this
			-- path also can't be time-warped.
			effWarp = 1
			if inAtmo and warp > 1 then
				self._input:ResetWarp()
			end
			local k = A.dragCoeff * self._vehicle:GetDragArea() / math.max(self._vehicle:GetCurrentMass(), 1e-3)
			self._state = Orbit.integrate(self._state, self._mu, dt, function(p2, v2)
				local ax, ay, az = 0, 0, 0
				if powered then
					ax, ay, az = nose.X * thrustAccel, nose.Y * thrustAccel, nose.Z * thrustAccel
				end
				local r2 = math.sqrt(p2.x * p2.x + p2.y * p2.y + p2.z * p2.z)
				local alt2 = r2 - self._bodyRadius
				if alt2 < A.top then
					-- a_drag = -k * densityFrac * |v| * v  (opposes velocity)
					local rho = math.exp(-math.max(alt2, 0) / A.scaleHeight)
					local speed = math.sqrt(v2.x * v2.x + v2.y * v2.y + v2.z * v2.z)
					local d = -k * rho * speed
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

		self:_checkTouchdown(nose) -- sets _landed / _crashed / _tipping + status
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

	self._powered = powered
	self._origin:UpdateFor(self._state.position)
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
		tele = self._vehicle:GetTelemetry(throttle),
	})
end

-- Terrain slope (radians) under a sim position, from the heightfield gradient.
function FlightController:_terrainSlope(upv)
	local R = self._bodyRadius
	local ref = (math.abs(upv.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local t1 = upv:Cross(ref).Unit
	local t2 = upv:Cross(t1).Unit
	local eps = 12
	local function hAt(offset)
		local d = (upv * R + offset).Unit
		return Planet.radiusForUnit(d.X, d.Y, d.Z)
	end
	local dh1 = hAt(t1 * eps) - hAt(-t1 * eps)
	local dh2 = hAt(t2 * eps) - hAt(-t2 * eps)
	local grad = math.sqrt(dh1 * dh1 + dh2 * dh2) / (2 * eps)
	return math.atan(grad)
end

-- If the craft has reached the surface, rest it and decide clean land vs tip/crash.
function FlightController:_checkTouchdown(nose)
	local p = self._state.position
	local nr = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local surf = Planet.radiusForSim(p)
	local hasLegs = self._vehicle:HasLegs()
	local restR = surf + (hasLegs and Config.LEGS.standHeight or 0)

	if nr >= restR then
		self._landed = false
		return
	end

	local upd = unit(p) or Orbit.vec(0, 1, 0)
	local upv = Vector3.new(upd.x, upd.y, upd.z)
	local vel = self._state.velocity
	local velv = Vector3.new(vel.x, vel.y, vel.z)
	local impact = velv.Magnitude
	local horiz = velv - upv * velv:Dot(upv)
	local horizSpeed = horiz.Magnitude
	local nosev = Vector3.new(nose.X, nose.Y, nose.Z)
	local noseTilt = math.acos(math.clamp(nosev:Dot(upv), -1, 1))
	local slope = self:_terrainSlope(upv)

	-- Rest the craft on the surface (feet on the ground).
	local s = restR / nr
	self._state.position = Orbit.vec(p.x * s, p.y * s, p.z * s)
	self._state.velocity = Orbit.vec(0, 0, 0)
	self._landed = true

	local L = Config.LANDING
	local tiltLim = hasLegs and L.maxTiltLegs or L.maxTiltBare
	local horizLim = hasLegs and L.maxHorizLegs or L.maxHorizBare
	local slopeLim = hasLegs and L.maxSlopeLegs or L.maxSlopeBare

	local unstable = (noseTilt > tiltLim) or (horizSpeed > horizLim) or (slope > slopeLim)
	local tooHard = impact > Config.FLIGHT.landSpeed

	if unstable then
		self._crashed = true
		self:_beginTip(upv, horiz, nosev)
		self._status = "Crashed"
	elseif tooHard then
		self._crashed = true
		self._status = "Crashed"
	else
		self._crashed = false
		self._status = "Landed"
	end
end

function FlightController:_beginTip(upv, horiz, nosev)
	self._tipping = true
	self._tipProgress = 0
	local tipDir = horiz
	if tipDir.Magnitude < 0.1 then
		tipDir = nosev - upv * nosev:Dot(upv) -- the way the nose already leans
	end
	if tipDir.Magnitude < 0.1 then
		tipDir = upv:Cross(Vector3.xAxis)
		if tipDir.Magnitude < 0.1 then
			tipDir = upv:Cross(Vector3.zAxis)
		end
	end
	tipDir = tipDir.Unit
	local axis = upv:Cross(tipDir)
	self._tipAxis = (axis.Magnitude > 1e-3) and axis.Unit or Vector3.xAxis
	self._tipStartAttitude = self._attitude
end

function FlightController:_advanceTip(dt)
	self._tipProgress = math.min(1, self._tipProgress + dt / Config.LANDING.tipDuration)
	local angle = self._tipProgress * math.rad(95) -- fall just past horizontal
	self._attitude = CFrame.fromAxisAngle(self._tipAxis, angle) * self._tipStartAttitude
	if self._tipProgress >= 1 then
		self._tipping = false -- stays crashed (held by the crashed branch)
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
