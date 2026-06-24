--[[
	DebrisController
	Owner of: separated debris (spent stages, jettisoned fairings) as SIM bodies.

	When a stage separates, its parts used to become Roblox physics objects -- they fell
	under the engine's own gravity and ignored the planet entirely. Instead, each dropped
	clump is tracked here as a little ballistic body in the SAME sim frame as the craft:
	it falls under the body's real gravity, takes atmospheric drag (so it slows and reenters),
	tumbles, and is drawn through the floating origin like everything else. Anchored parts,
	moved by PivotTo each frame -- the Roblox solver never touches them.

	Pieces despawn on surface impact, after Config.DEBRIS.maxAge, or when the count cap is hit.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local DebrisController = {}

local function mag(v)
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function DebrisController:Init()
	self._items = {}
end

function DebrisController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._flight = Registry:Get("FlightController")

	-- Propagate + render on the flight tick (so debris shares the craft's clock and origin).
	self._flight:GetUpdatedSignal():Connect(function(_, info)
		self:_update(info)
	end)
end

-- Hand a freshly-separated clump to the sim. `model` is an ANCHORED Model already positioned
-- in the world (its WorldPivot at `worldCenter`); `sepImpulse` / `spin` are world-space.
function DebrisController:Spawn(model, worldCenter, sepImpulse, spin)
	if not model then
		return
	end
	local info = self._flight:GetActiveBodyInfo()
	local craft = self._flight:GetState()
	-- Convert the world centre to a body-relative sim position; inherit the craft's velocity
	-- (relative to the same body) plus the separation kick.
	local absSim = self._origin:ToSim(worldCenter)
	local pos = Orbit.vec(absSim.x - info.center.x, absSim.y - info.center.y, absSim.z - info.center.z)
	local vel = Orbit.vec(
		craft.velocity.x + (sepImpulse and sepImpulse.X or 0),
		craft.velocity.y + (sepImpulse and sepImpulse.Y or 0),
		craft.velocity.z + (sepImpulse and sepImpulse.Z or 0)
	)

	-- Count cap: drop the oldest.
	while #self._items >= (Config.DEBRIS.maxCount or 10) do
		local oldest = table.remove(self._items, 1)
		if oldest and oldest.model then
			oldest.model:Destroy()
		end
	end

	model.Parent = Workspace
	self._items[#self._items + 1] = {
		model = model,
		bodyId = info.id,
		mu = info.mu,
		radius = info.radius,
		pos = pos,
		vel = vel,
		spin = (spin and spin.Magnitude > 1e-4) and spin or Vector3.new(0.25, 0.12, 0.18),
		orient = CFrame.identity,
		age = 0,
	}
end

function DebrisController:_clear()
	for _, d in ipairs(self._items) do
		if d.model then
			d.model:Destroy()
		end
	end
	self._items = {}
end

function DebrisController:_update(info)
	-- Debris only exists in flight; wipe it on return to the VAB / menu / relaunch.
	if not info or info.mode ~= "Flight" then
		if #self._items > 0 then
			self:_clear()
		end
		return
	end
	if #self._items == 0 then
		return
	end

	-- Real frame dt (clamped for integrator stability); debris isn't time-warped.
	local dt = math.clamp(info.dt or 0, 0, 0.1)
	local A = Config.ATMOSPHERE
	local kDrag = Config.DEBRIS.drag or 0.0007
	local maxAge = Config.DEBRIS.maxAge or 150

	local survivors = {}
	for _, d in ipairs(self._items) do
		d.age += dt
		if d.age < maxAge and dt > 0 then
			d.pos, d.vel = self:_step(d, dt, A, kDrag)
		end

		-- Impact with the surface, or aged out -> remove.
		local r = mag(d.pos)
		local surf = d.radius
		if d.bodyId == "planet" and r > 1e-3 then
			surf = Planet.radiusForUnit(d.pos.x / r, d.pos.y / r, d.pos.z / r)
		end
		if d.age >= maxAge or r <= surf then
			if d.model then
				d.model:Destroy()
			end
		else
			local center = self._flight:GetBodyCenter(d.bodyId)
			local world = self._origin:ToRender(Orbit.vec(center.x + d.pos.x, center.y + d.pos.y, center.z + d.pos.z))
			local axis = (d.spin.Magnitude > 1e-4) and d.spin.Unit or Vector3.yAxis
			d.orient = CFrame.fromAxisAngle(axis, d.spin.Magnitude * dt) * d.orient
			d.model:PivotTo(CFrame.new(world) * d.orient)
			survivors[#survivors + 1] = d
		end
	end
	self._items = survivors
end

-- One ballistic step: the body's two-body gravity (built into Orbit.integrate) plus
-- atmospheric drag (planet only), opposing velocity.
function DebrisController:_step(d, dt, A, kDrag)
	local state = Orbit.integrate({ position = d.pos, velocity = d.vel }, d.mu, dt, function(p, v)
		if d.bodyId ~= "planet" then
			return Orbit.vec(0, 0, 0)
		end
		local alt = mag(p) - d.radius
		if alt >= A.top then
			return Orbit.vec(0, 0, 0)
		end
		local rho = math.exp(-math.max(alt, 0) / A.scaleHeight)
		local speed = mag(v)
		local dmag = -kDrag * rho * speed
		return Orbit.vec(v.x * dmag, v.y * dmag, v.z * dmag)
	end)
	return state.position, state.velocity
end

return DebrisController
