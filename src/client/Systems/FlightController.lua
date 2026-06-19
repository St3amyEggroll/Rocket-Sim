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

	self._state = { position = Orbit.vec(body.radius, 0, 0), velocity = Orbit.vec(0, 0, 0) }
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.xAxis, Vector3.yAxis) -- nose = +X (radial up)
	self._status = "VAB"
	self._powered = false
	self._landed = true
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
	self._state = { position = Orbit.vec(self._bodyRadius, 0, 0), velocity = Orbit.vec(0, 0, 0) }
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.xAxis, Vector3.yAxis)
	self._landed = true
	self._status = (mode == "Flight") and "Landed" or "VAB"
	self._origin:SetOrigin(self._state.position)
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

function FlightController:_mapScale()
	if not self._input:GetMapMode() then
		return 1
	end
	local p = self._state.position
	local rNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local ro = Orbit.getReadout(self._state, self._mu)
	local apoR = (ro.apoapsis < math.huge) and ro.apoapsis or rNow
	local frameR = math.max(apoR, rNow, self._bodyRadius * 1.2)
	return Config.RENDER.mapViewRadius / frameR
end

function FlightController:_fire(extra)
	extra.mode = self._mode:GetMode()
	extra.nose = self._attitude.LookVector
	extra.attitude = self._attitude
	extra.mapMode = self._input:GetMapMode()
	extra.mapScale = self:_mapScale()
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
	local throttle = self._input:GetThrottle()
	local warp = self._input:GetTimeWarp()

	local sas = self:_updateAttitude(dt, pos, self._state.velocity)
	local nose = self._attitude.LookVector
	local powered = false

	if self._landed and throttle <= 0 then
		self._status = "Landed"
	else
		local accelMag = self._vehicle:GetThrustAccel(throttle)
		if throttle > 0 and accelMag > 0 then
			local a = Orbit.vec(nose.X * accelMag, nose.Y * accelMag, nose.Z * accelMag)
			self._state = Orbit.integrate(self._state, self._mu, dt, function()
				return a
			end)
			self._vehicle:ConsumeFuel(dt, throttle)
			powered = true
		else
			self._state = Orbit.propagate(self._state, self._mu, dt * warp)
		end

		local p = self._state.position
		local nr = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if nr < self._bodyRadius then
			local s = self._bodyRadius / nr
			self._state.position = Orbit.vec(p.x * s, p.y * s, p.z * s)
			self._state.velocity = Orbit.vec(0, 0, 0)
			self._landed = true
			self._status = "Landed"
		else
			self._landed = false
			self._status = powered and "Powered" or "Coasting"
		end
	end

	self._powered = powered
	self._origin:UpdateFor(self._state.position)
	self:_fire({
		pointDir = nose,
		dt = dt,
		throttle = throttle,
		warp = warp,
		sas = sas,
		powered = powered,
		status = self._status,
		tele = self._vehicle:GetTelemetry(throttle),
	})
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
