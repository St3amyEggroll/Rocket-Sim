--[[
	TerrainController
	Owner of: the planet's appearance at two levels of detail.

	  * The LOW-detail body is a real grass Ball part (radius = Config.BODY.radius).
	    It is a genuine part (<=1024 radius), so it renders at any distance and
	    never culls. It is always present and is what you see from orbit.

	  * The HIGH-detail surface is a curved crust of real Roblox terrain laid only
	    around the point of the sphere directly under the craft. Solid voxel terrain
	    over a 1000-stud sphere would be ~65M voxels (infeasible), so instead we
	    stream a local crust that follows the rocket across the surface: it lays in
	    when you are near the ground, re-lays as you travel laterally, and clears
	    when you climb away - at which point the Ball alone is the LOD.

	Because the floating origin is fixed at the body centre, terrain world
	coordinates equal sim coordinates, so the crust lines up with the Ball exactly.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local TerrainController = {}

function TerrainController:Init()
	self._hasTerrain = false -- is a crust currently laid?
	self._busy = false -- a stream-in coroutine is running
	self._genDir = nil -- unit Vector3 the current crust is centred on
end

function TerrainController:Start()
	self:_buildBody()

	local terrain = Workspace.Terrain
	terrain:Clear()
	pcall(function()
		terrain:SetMaterialColor(Enum.Material.Grass, Config.BODY.grassColor)
	end)

	local Flight = Registry:Get("FlightController")
	Flight:GetUpdatedSignal():Connect(function(state)
		self:_onUpdate(state)
	end)
end

-- The always-present low-detail body.
function TerrainController:_buildBody()
	local body = Config.BODY
	local R = body.radius
	local planet = Instance.new("Part")
	planet.Name = "Planet"
	planet.Shape = Enum.PartType.Ball
	planet.Size = Vector3.new(R * 2, R * 2, R * 2) -- <=2048 diameter: a real, never-culled part
	planet.Anchored = true
	planet.CanCollide = true
	planet.Color = body.grassColor
	planet.Material = Enum.Material.Grass
	planet.CFrame = CFrame.new(0, 0, 0)
	planet.Parent = Workspace
	self._planet = planet
end

-- Per-frame LOD decision (cheap vector math; heavy work is gated behind _busy).
function TerrainController:_onUpdate(state)
	if self._busy then
		return
	end

	local T = Config.TERRAIN
	local R = Config.BODY.radius
	local p = state.position
	local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local alt = r - R

	local dir = Vector3.new(p.x, p.y, p.z)
	dir = (dir.Magnitude > 1e-3) and dir.Unit or Vector3.yAxis

	-- Far from the surface: drop the crust, let the Ball be the LOD.
	if alt > T.streamOutAlt then
		if self._hasTerrain then
			Workspace.Terrain:Clear()
			self._hasTerrain = false
			self._genDir = nil
		end
		return
	end

	-- Near the surface: make sure a crust is laid under us. The gap between
	-- streamInAlt and streamOutAlt is hysteresis so the crust does not flicker.
	if alt <= T.streamInAlt then
		local need = false
		if not self._hasTerrain then
			need = true
		elseif self._genDir then
			local dot = math.clamp(dir:Dot(self._genDir), -1, 1)
			local arc = math.acos(dot) * R -- distance travelled along the surface
			if arc > T.regenDistance then
				need = true
			end
		end

		if need then
			self._busy = true
			task.spawn(function()
				self:_buildCrust(dir)
				self._genDir = dir
				self._hasTerrain = true
				self._busy = false
			end)
		end
	end
end

-- Lay a curved crust of terrain that hugs the sphere around `dir`.
function TerrainController:_buildCrust(dir)
	local T = Config.TERRAIN
	local R = Config.BODY.radius
	local terrain = Workspace.Terrain
	terrain:Clear()

	-- Tangent frame at the cap centre.
	local n = dir
	local ref = (math.abs(n.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local t1 = n:Cross(ref).Unit
	local t2 = n:Cross(t1).Unit

	local half = T.capHalfWidth
	local spacing = T.capSpacing
	local ballR = T.capBallRadius
	local amp = T.reliefAmp
	local freq = T.reliefFreq
	local maxSq = half * half
	local placed = 0

	for u = -half, half, spacing do
		for v = -half, half, spacing do
			if u * u + v * v <= maxSq then
				-- Project the tangent-plane sample onto the sphere direction.
				local d = (n * R + t1 * u + t2 * v).Unit
				-- Rolling-hill relief from Perlin noise over the surface point.
				local sp = d * R
				local h = R + math.noise(sp.X * freq, sp.Y * freq, sp.Z * freq) * amp
				-- Centre the fill-ball just below the surface so its top sits near h,
				-- giving the crust real thickness for landing / walking on.
				local center = d * (h - ballR * 0.5)
				terrain:FillBall(center, ballR, Enum.Material.Grass)

				placed += 1
				if placed % T.ballsPerFrame == 0 then
					task.wait()
				end
			end
		end
	end
end

-- For the debug overlay: which LOD is currently showing.
function TerrainController:GetLODState()
	if self._busy then
		return "crust: streaming in..."
	elseif self._hasTerrain then
		return "crust: ON (terrain)"
	else
		return "crust: OFF (Ball LOD)"
	end
end

return TerrainController
