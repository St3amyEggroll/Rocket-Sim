--[[
	FlightController
	Owner of: the craft's sim State, the active body mu, and flight status. Drives
	the master per-frame loop and respects the game mode.

	VAB mode    -> the craft sits on the launch pad (no sim); still broadcasts so
	               the rocket renders on the planet.
	Flight mode -> on entering, the craft is placed in a low orbit with full fuel.
	               throttle > 0 burns the active stage (Orbit.integrate, real dt,
	               thrust accel = stage thrust / current mass; fuel is consumed and
	               Space stages). throttle == 0 coasts (Orbit.propagate, warped).
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

local function negate(v)
	return Orbit.vec(-v.x, -v.y, -v.z)
end

function FlightController:Init()
	local body = Config.BODY
	self._mu = body.mu
	self._bodyRadius = body.radius
	self._orbitAlt = Config.LAUNCH.orbitAltitude

	-- Start on the pad (VAB).
	self._state = { position = Orbit.vec(body.radius, 0, 0), velocity = Orbit.vec(0, 0, 0) }
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
	if mode == "Flight" then
		self._vehicle:ResetRuntime()
		local r = self._bodyRadius + self._orbitAlt
		self._state = {
			position = Orbit.vec(r, 0, 0),
			velocity = Orbit.vec(0, 0, Orbit.circularSpeed(r, self._mu)),
		}
		self._landed = false
		self._status = "Coasting"
	else
		self._vehicle:ResetRuntime() -- rebuild the full rocket for the pad preview
		self._state = { position = Orbit.vec(self._bodyRadius, 0, 0), velocity = Orbit.vec(0, 0, 0) }
		self._landed = true
		self._status = "VAB"
	end
	self._origin:SetOrigin(self._state.position)
end

function FlightController:_thrustDirection(mode, pos, vel)
	if mode == "Retrograde" then
		local d = unit(vel) or unit(pos)
		return d and negate(d) or nil
	elseif mode == "RadialOut" then
		return unit(pos)
	elseif mode == "RadialIn" then
		local d = unit(pos)
		return d and negate(d) or nil
	end
	return unit(vel) or unit(pos)
end

function FlightController:_step(rawDt)
	local mode = self._mode:GetMode()
	local pos = self._state.position

	if mode ~= "Flight" then
		-- VAB: hold on the pad, rocket points "up" (radial out).
		self._status = "VAB"
		self._powered = false
		self._updateCount += 1
		self._origin:UpdateFor(self._state.position)
		self.Updated:Fire(self._state, {
			mode = mode,
			pointDir = unit(pos) or Orbit.vec(1, 0, 0),
			throttle = 0,
			powered = false,
			status = "VAB",
			warp = 1,
			mapMode = self._input:GetMapMode(),
			mu = self._mu,
			bodyRadius = self._bodyRadius,
		})
		return
	end

	local dt = math.clamp(rawDt, 0, Config.FLIGHT.maxDt)
	local throttle = self._input:GetThrottle()
	local tmode = self._input:GetThrustMode()
	local warp = self._input:GetTimeWarp()
	local powered = false
	local thrustDir = nil

	if self._landed and throttle <= 0 then
		self._status = "Landed"
	else
		local accelMag = self._vehicle:GetThrustAccel(throttle)
		if throttle > 0 and accelMag > 0 then
			thrustDir = self:_thrustDirection(tmode, pos, self._state.velocity)
			local extraAccel = function(p2, v2)
				local d = self:_thrustDirection(tmode, p2, v2)
				if not d then
					return Orbit.vec(0, 0, 0)
				end
				return Orbit.vec(d.x * accelMag, d.y * accelMag, d.z * accelMag)
			end
			self._state = Orbit.integrate(self._state, self._mu, dt, extraAccel)
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
	self._updateCount += 1

	-- Pointing direction for the renderer.
	local p2 = self._state.position
	local v2 = self._state.velocity
	local pd
	if powered and thrustDir then
		pd = thrustDir
	else
		local sp = math.sqrt(v2.x * v2.x + v2.y * v2.y + v2.z * v2.z)
		pd = (sp > 1e-3) and unit(v2) or (unit(p2) or Orbit.vec(1, 0, 0))
	end

	self._origin:UpdateFor(self._state.position)

	self.Updated:Fire(self._state, {
		mode = mode,
		pointDir = pd,
		dt = dt,
		throttle = throttle,
		thrustMode = tmode,
		warp = warp,
		mapMode = self._input:GetMapMode(),
		powered = powered,
		status = self._status,
		mu = self._mu,
		bodyRadius = self._bodyRadius,
		tele = self._vehicle:GetTelemetry(throttle),
	})
end

function FlightController:GetState()
	return self._state
end

function FlightController:GetMu(): number
	return self._mu
end

function FlightController:GetBodyRadius(): number
	return self._bodyRadius
end

function FlightController:GetUpdatedSignal()
	return self.Updated
end

function FlightController:GetUpdateCount(): number
	return self._updateCount
end

function FlightController:GetReadout()
	return Orbit.getReadout(self._state, self._mu, self._bodyRadius)
end

return FlightController
