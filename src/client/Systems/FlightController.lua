--[[
	FlightController
	Owner of: the master flight loop, the attitude TARGET, the active body and
	flight status. The craft itself is a real Roblox rigid body built by
	CraftRenderer; this module drives it:

	  * gravity  -> a radial VectorForce (Workspace.Gravity is 0),
	  * thrust   -> a VectorForce along the nose while throttled (fuel burns),
	  * steering -> an AlignOrientation chasing the attitude target (WASD/QE) or a
	                SAS hold (1-5),
	and reads the body's transform/velocity back each frame for everyone else.

	The craft collides, tips and rests on the terrain for real, so landing is
	physical: touch down slow, upright, on its legs. Hard touchdowns just flag a red
	"Crashed" status (you can relaunch).

	Time warp cannot run a physics sim, so warp switches to analytic Kepler
	propagation ("on rails"): the body is anchored and moved kinematically, then
	handed back to physics (with its velocity restored) when warp ends.
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

local function physProps(density)
	return PhysicalProperties.new(density, Config.PHYSICS.partFriction, Config.PHYSICS.partElasticity, 1, 1)
end

local function unit(v)
	local m = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if m < 1e-9 then
		return nil
	end
	return Orbit.vec(v.x / m, v.y / m, v.z / m)
end

local function v3(d)
	return d and Vector3.new(d.x, d.y, d.z) or nil
end

function FlightController:Init()
	local body = Config.BODY
	self._mu = body.mu
	self._bodyRadius = body.radius
	self._turnStart = Config.LAUNCH.turnStartAlt
	self._turnEnd = Config.LAUNCH.turnEndAlt
	self._launchRadius = Planet.radiusForSim(Orbit.vec(0, body.radius, 0))

	self._state = { position = Orbit.vec(0, self._launchRadius, 0), velocity = Orbit.vec(0, 0, 0) }
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.yAxis, Vector3.xAxis) -- LookVector = target nose
	self._status = "VAB"
	self._powered = false
	self._landed = true
	self._crashed = false
	self._onRails = false
	self._peakDescent = 0
	self._throttle = 0
	self._warp = 1
	self._sas = "Ascent"
	self._updateCount = 0
	self.Updated = Signal.new()
end

function FlightController:Start()
	self._input = Registry:Get("InputController")
	self._origin = Registry:Get("FloatingOriginController")
	self._mode = Registry:Get("GameModeController")
	self._vehicle = Registry:Get("VehicleController")
	self._crafter = Registry:Get("CraftRenderer")
	self._handles = self._crafter:GetCraft()

	self._mode.ModeChanged:Connect(function(m)
		self:_onMode(m)
	end)
	self._input:GetStageSignal():Connect(function()
		if self._mode:GetMode() == "Flight" then
			self._vehicle:Stage()
		end
	end)
	self._vehicle.Changed:Connect(function()
		self:_onCraftChanged()
	end)

	self:_onMode(self._mode:GetMode())

	RunService:BindToRenderStep("RocketSim_Flight", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
end

-- ---------------------------------------------------------------- placement ----

function FlightController:_spawnCFrame()
	local r = self._launchRadius + Config.LEGS.drop + Config.PHYSICS.spawnClearance
	return CFrame.fromMatrix(Vector3.new(0, r, 0), Vector3.xAxis, Vector3.yAxis) -- UpVector = +Y = nose
end

function FlightController:_holdOnPad(handles)
	if not handles or not handles.root or not handles.root.Parent then
		return
	end
	local sp = self:_spawnCFrame()
	handles.root.Anchored = true
	handles.model:PivotTo(sp)
	handles.root.AssemblyLinearVelocity = Vector3.zero
	handles.gravForce.Force = Vector3.zero
	handles.thrustForce.Force = Vector3.zero
	self._state = { position = Orbit.vec(0, sp.Position.Y, 0), velocity = Orbit.vec(0, 0, 0) }
end

function FlightController:_onMode(mode)
	self._vehicle:ResetRuntime() -- fires Changed -> craft rebuilt + handles refreshed
	self._handles = self._crafter:GetCraft()
	self._lastDensity = nil
	self._attitude = CFrame.lookAt(Vector3.zero, Vector3.yAxis, Vector3.xAxis)
	self._onRails = false
	self._peakDescent = 0
	self._crashed = false
	self._landed = true
	self._origin:SetOrigin(Orbit.vec(0, 0, 0))

	if mode == "Flight" then
		local h = self._handles
		local sp = self:_spawnCFrame()
		if h and h.root then
			h.root.Anchored = false
			h.model:PivotTo(sp)
			h.root.AssemblyLinearVelocity = Vector3.zero
			h.root.AssemblyAngularVelocity = Vector3.zero
		end
		self._state = { position = Orbit.vec(0, sp.Position.Y, 0), velocity = Orbit.vec(0, 0, 0) }
		self._status = "Landed"
	else
		self:_holdOnPad(self._handles)
		self._status = "VAB"
	end
end

-- Craft was rebuilt (staging / VAB edit): keep flying continuously.
function FlightController:_onCraftChanged()
	self._handles = self._crafter:GetCraft()
	self._lastDensity = nil
	local h = self._handles
	if not h or not h.root then
		return
	end
	if self._mode:GetMode() == "Flight" then
		local p = self._state.position
		local cf = CFrame.fromMatrix(Vector3.new(p.x, p.y, p.z), self._attitude.RightVector, self._attitude.LookVector)
		h.model:PivotTo(cf)
		if self._onRails then
			h.root.Anchored = true
		else
			h.root.Anchored = false
			h.root.AssemblyLinearVelocity = v3(self._state.velocity)
			h.root.AssemblyAngularVelocity = Vector3.zero
		end
	else
		self:_holdOnPad(h)
	end
end

-- ----------------------------------------------------------------- attitude ----

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

-- Update the attitude TARGET (LookVector = desired nose). The AlignOrientation
-- on the body chases this; manual input switches SAS to Manual.
function FlightController:_updateAttitude(dt, pos, vel)
	local pitch, yaw, roll = self._input:GetAttitudeInput()
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

-- AlignOrientation CFrame whose UpVector is the TARGET nose (root +Y aligns to it).
-- The roll axis is taken from the craft's CURRENT orientation, so the control only
-- ever corrects pitch/yaw to point the nose and never fights/snaps roll (which was
-- causing the craft to spin out on launch).
function FlightController:_alignCFrame(handles)
	local nose = self._attitude.LookVector
	local cr = handles.root.CFrame.RightVector
	local right = cr - nose * cr:Dot(nose) -- current right, projected off the nose
	if right.Magnitude < 1e-3 then
		cr = handles.root.CFrame.UpVector
		right = cr - nose * cr:Dot(nose)
	end
	right = (right.Magnitude > 1e-3) and right.Unit or Vector3.xAxis
	return CFrame.fromMatrix(Vector3.zero, right, nose)
end

-- ------------------------------------------------------------------- masses ----

function FlightController:_applyMass(handles)
	local mass = self._vehicle:GetCurrentMass()
	if mass <= 0 then
		return
	end
	local density = mass / handles.totalVolume
	if self._lastDensity and math.abs(density - self._lastDensity) <= self._lastDensity * 0.01 then
		return
	end
	local props = physProps(density)
	for _, p in ipairs(handles.parts) do
		p.CustomPhysicalProperties = props
	end
	self._lastDensity = density
end

-- --------------------------------------------------------------------- loop ----

function FlightController:_readState(handles)
	local root = handles.root
	local p = root.Position
	local v = root.AssemblyLinearVelocity
	self._state = { position = Orbit.vec(p.X, p.Y, p.Z), velocity = Orbit.vec(v.X, v.Y, v.Z) }
end

function FlightController:_physicsStep(handles, dt, throttle)
	local root = handles.root
	root.Anchored = false
	self:_applyMass(handles)
	self:_readState(handles)

	local pos = self._state.position
	local vel = self._state.velocity
	local r = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	local radialUp = unit(pos) or Orbit.vec(0, 1, 0)

	local sas = self:_updateAttitude(dt, pos, vel)
	self._sas = sas

	-- Radial gravity at the centre of mass.
	local mass = self._vehicle:GetCurrentMass()
	local g = self._mu / (r * r)
	handles.gravForce.Force = Vector3.new(-radialUp.x, -radialUp.y, -radialUp.z) * (mass * g)

	-- Thrust along the nose.
	local powered = false
	local thrust = self._vehicle:GetCurrentThrust(throttle)
	if throttle > 0 and thrust > 0 then
		handles.thrustForce.Force = Vector3.new(0, thrust, 0)
		self._vehicle:ConsumeFuel(dt, throttle)
		powered = true
	else
		handles.thrustForce.Force = Vector3.zero
	end

	handles.align.CFrame = self:_alignCFrame(handles)

	-- Landing / crash classification.
	local surf = Planet.radiusForSim(pos)
	local radarAlt = r - surf
	local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
	local vertSpeed = vel.x * radialUp.x + vel.y * radialUp.y + vel.z * radialUp.z
	local atGround = radarAlt < Config.PHYSICS.groundContactAlt

	local wantLanded = (throttle <= 0 and atGround and speed < Config.PHYSICS.restSpeed)
	if wantLanded and not self._landed then
		self._landed = true
		self._crashed = self._peakDescent > Config.FLIGHT.landSpeed
	elseif self._landed and (speed > Config.PHYSICS.liftoffSpeed or radarAlt > Config.PHYSICS.groundContactAlt * 1.5) then
		self._landed = false
		self._crashed = false
		self._peakDescent = 0
	end
	if not self._landed then
		self._peakDescent = math.max(self._peakDescent, -vertSpeed)
	end

	self._powered = powered
	if self._landed then
		self._status = self._crashed and "Crashed" or "Landed"
	else
		self._status = powered and "Powered" or "Coasting"
	end

	-- Attitude control acts like reaction wheels: it steers in flight but is
	-- released once at rest, so a craft on a steep slope (or that came down
	-- tilted / on no legs) tips over for real instead of being held upright.
	handles.align.Enabled = not self._landed
end

function FlightController:_railsStep(handles, dt, warp)
	local root = handles.root
	if not self._onRails then
		self._onRails = true
		self:_readState(handles)
		self._railState = {
			position = Orbit.vec(self._state.position.x, self._state.position.y, self._state.position.z),
			velocity = Orbit.vec(self._state.velocity.x, self._state.velocity.y, self._state.velocity.z),
		}
		root.Anchored = true
		handles.gravForce.Force = Vector3.zero
		handles.thrustForce.Force = Vector3.zero
	end

	self._sas = self:_updateAttitude(dt, self._railState.position, self._railState.velocity)
	self._railState = Orbit.propagate(self._railState, self._mu, dt * warp)
	self._state = self._railState

	local p = self._railState.position
	handles.model:PivotTo(CFrame.fromMatrix(Vector3.new(p.x, p.y, p.z), self._attitude.RightVector, self._attitude.LookVector))

	self._powered = false
	self._landed = false
	self._status = "Coasting"
end

function FlightController:_exitRails(handles)
	self._onRails = false
	local root = handles.root
	root.Anchored = false
	root.AssemblyLinearVelocity = v3(self._railState.velocity)
	root.AssemblyAngularVelocity = Vector3.zero
end

function FlightController:_step(rawDt)
	self._updateCount += 1
	local handles = self._handles
	if not handles or not handles.root or not handles.root.Parent then
		self._handles = self._crafter:GetCraft()
		handles = self._handles
		if not handles then
			return
		end
	end

	local mode = self._mode:GetMode()
	if mode ~= "Flight" then
		self._throttle = 0
		self._warp = 1
		self._powered = false
		self._sas = "VAB"
		self._status = "VAB"
		self:_holdOnPad(handles)
		self:_fire()
		return
	end

	local dt = math.clamp(rawDt, 0, Config.FLIGHT.maxDt)
	self._throttle = self._input:GetThrottle()
	self._warp = self._input:GetTimeWarp()

	-- On-rails warp is only honoured well clear of the ground, so you cannot warp
	-- while landed or warp straight into the terrain.
	local p = self._state.position
	local alt = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - self._bodyRadius
	if self._warp > 1 and alt > Config.PHYSICS.minWarpAlt then
		self:_railsStep(handles, dt, self._warp)
	else
		if self._onRails then
			self:_exitRails(handles)
		end
		self:_physicsStep(handles, dt, self._throttle)
	end

	self:_fire()
end

-- ------------------------------------------------------------------- output ----

-- Map is drawn TO SCALE around the real planet (see MapViewController).
function FlightController:_mapInfo()
	local p = self._state.position
	local rNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local ro = Orbit.getReadout(self._state, self._mu)
	local apoR = (ro.apoapsis < math.huge) and ro.apoapsis or rNow
	local frameRender = math.max(apoR, rNow, self._bodyRadius * 1.3)
	return 1, frameRender
end

function FlightController:_fire()
	local h = self._handles
	local nose, rollRef
	if h and h.root and h.root.Parent then
		nose = h.root.CFrame.UpVector
		rollRef = h.root.CFrame.LookVector
	else
		nose = self._attitude.LookVector
		rollRef = self._attitude.UpVector
	end
	local attInfo = CFrame.lookAt(Vector3.zero, nose, rollRef)
	local mapScale, mapFrame = self:_mapInfo()

	self.Updated:Fire(self._state, {
		mode = self._mode:GetMode(),
		pointDir = nose,
		attitude = attInfo,
		throttle = self._throttle or 0,
		warp = self._warp or 1,
		sas = self._sas or "Manual",
		powered = self._powered or false,
		status = self._status or "Coasting",
		tele = self._vehicle:GetTelemetry(self._throttle or 0),
		mapMode = self._input:GetMapMode(),
		mapScale = mapScale,
		mapFrameRadius = mapFrame,
		mu = self._mu,
		bodyRadius = self._bodyRadius,
	})
end

-- ------------------------------------------------------------------ getters ----

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
