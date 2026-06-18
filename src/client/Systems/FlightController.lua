--[[
	FlightController
	Owner of: the craft's sim State (double-precision position/velocity), the
	active body mu, and the flight status. Drives the master per-frame loop.

	Each frame:
	  * throttle > 0  -> POWERED: Orbit.integrate (gravity + thrust) every frame.
	  * throttle == 0 -> COASTING: Orbit.propagate (analytic; time-warp ready).
	Then it maintains the floating origin and fires "Updated" so the renderer,
	camera and HUD can react. This is the proof-of-pipeline loop for Phase 1.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))

local FlightController = {}

-- Normalised Vec3, or nil for a (near) zero vector.
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

	local r = body.radius + Config.START.altitude
	local speed = Orbit.circularSpeed(r, body.mu)

	-- Start in a clean low circular orbit in the XZ plane:
	-- position along +X, velocity along +Z.
	self._state = {
		position = Orbit.vec(r, 0, 0),
		velocity = Orbit.vec(0, 0, speed),
	}

	self._status = "Coasting"
	self._powered = false
	self._landed = false

	-- The per-frame broadcast. Created in Init so listeners can connect in their
	-- own Start (before this controller's Start kicks off the loop).
	self.Updated = Signal.new()
end

function FlightController:Start()
	self._input = Registry:Get("InputController")
	self._origin = Registry:Get("FloatingOriginController")

	-- Run after the engine's internal camera step (Camera priority) so our
	-- Scriptable camera CFrame, set inside the Updated broadcast, wins the frame.
	RunService:BindToRenderStep("RocketSim_Flight", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
end

-- Resolve a thrust direction (unit Vec3) for the current steering mode.
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
	-- Prograde (default). Falls back to "up" when nearly stationary.
	return unit(vel) or unit(pos)
end

function FlightController:_step(rawDt)
	local dt = math.clamp(rawDt, 0, Config.FLIGHT.maxDt)
	local mu = self._mu
	local R = self._bodyRadius

	local throttle = self._input:GetThrottle()
	local mode = self._input:GetThrustMode()
	local powered = false

	if self._landed and throttle <= 0 then
		-- Resting on the surface, engine off. Hold position (avoids a degenerate
		-- zero-velocity radial "coast" straight into the body).
		self._status = "Landed"
	else
		if throttle > 0 then
			-- POWERED: thrust acceleration handed to the integrator. Gravity is
			-- added inside Orbit.integrate, so we only supply thrust here.
			local mag = Config.CRAFT.thrustAccel * throttle
			local extraAccel = function(pos, vel)
				local dir = self:_thrustDirection(mode, pos, vel)
				if not dir then
					return Orbit.vec(0, 0, 0)
				end
				return Orbit.vec(dir.x * mag, dir.y * mag, dir.z * mag)
			end
			self._state = Orbit.integrate(self._state, mu, dt, extraAccel)
			powered = true
		else
			-- COASTING: analytic propagation (handles any dt -> time warp later).
			self._state = Orbit.propagate(self._state, mu, dt)
		end

		-- Surface contact: clamp to the surface and treat as landed.
		local p = self._state.position
		local nr = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if nr < R then
			local s = R / nr
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

	-- Keep the rendered universe centred on the craft.
	self._origin:UpdateFor(self._state.position)

	-- Broadcast to renderer / camera / HUD.
	self.Updated:Fire(self._state, {
		dt = dt,
		throttle = throttle,
		thrustMode = mode,
		powered = powered,
		status = self._status,
		mu = mu,
		bodyRadius = R,
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

function FlightController:GetReadout()
	return Orbit.getReadout(self._state, self._mu, self._bodyRadius)
end

return FlightController
