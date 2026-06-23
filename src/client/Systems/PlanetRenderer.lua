--[[
	PlanetRenderer
	Owner of: the always-visible planet body (the low-detail LOD) and its
	cosmetic atmosphere shell.

	The body is drawn as a MESH sphere (a Part with a SpecialMesh, sized via
	mesh.Scale) rather than a Ball part. A Ball part is capped at 1024 radius (the
	2048-stud part limit), which is fine for a small planet but cannot represent a
	multi-thousand-stud world; a SpecialMesh has no such cap, so the body renders at
	true scale right up to the surface and the streamed terrain (TerrainController)
	sits seamlessly on top of it -- regardless of how big Config.BODY.radius is.

	Roblox still will not draw a part whose (small) collision box is past the camera's
	far render range, so when the true centre is farther than maxRender we pull the
	sphere in along the line of sight and scale the mesh by the same factor: angular
	size and screen direction are preserved exactly, so it looks identical to the real
	body and shrinks to a dot as you leave -- it just never exits the render range.

	This is purely how the body is DRAWN for the camera; what terrain loads is keyed
	to the craft, not the camera (see TerrainController).
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local PlanetRenderer = {}

-- Part collision-box size for the mesh spheres: as large as the part cap allows, so
-- the body resists distance-culling out to low orbit. The visible size is driven
-- entirely by mesh.Scale = renderedDiameter / BASE.
local BASE = 2048

-- A CFrame at `pos` whose UP axis is `up` (a tile tangent to the sphere faces outward).
local function frameFromUp(pos, up)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(pos, pos + fwd.Unit, up)
end

function PlanetRenderer:Init()
	self._trueRadius = Planet.lodRadius()
	self._atmoRadius = Config.BODY.radius + Config.ATMOSPHERE.top
	-- Within maxRender the body is drawn at TRUE scale/position (mesh spheres have no
	-- size cap), so the surface and low orbit are seamless and never occlude the craft.
	-- Beyond it (high orbit / deep space, where pulling it in can't occlude anything)
	-- the angular-size proxy keeps it on screen. The threshold sits just above the
	-- surface + max zoom so the close view is always true-scale.
	self._maxRender = Config.BODY.radius + Config.CAMERA.distanceMax + 4000
end

function PlanetRenderer:_makeSphere(name, color, material, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(BASE, BASE, BASE)
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.CFrame = CFrame.new(0, 0, 0)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	p.Parent = Workspace
	return p, mesh
end

function PlanetRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")

	self._ball, self._ballMesh = self:_makeSphere("Planet", Config.BODY.lodColor or Config.BODY.grassColor, Enum.Material.SmoothPlastic, 0)
	-- Translucent atmosphere shell (purely cosmetic), drawn concentric with the body.
	self._atmo, self._atmoMesh = self:_makeSphere("Atmosphere", Config.ATMOSPHERE.color, Enum.Material.ForceField, 0.5)

	-- Biome shell: a layer of land-colored tiles over the base (ocean) sphere, so you see
	-- continents from orbit.
	self:_buildBiomeShell()

	-- Update after the camera has been positioned for this frame.
	RunService:BindToRenderStep("RocketSim_Planet", Enum.RenderPriority.Camera.Value + 2, function()
		self:_update()
	end)
end

-- Size a mesh sphere to a rendered DIAMETER and place its centre.
function PlanetRenderer:_apply(mesh, part, diameter, center)
	local s = diameter / BASE
	mesh.Scale = Vector3.new(s, s, s)
	part.CFrame = CFrame.new(center)
end

-- Build the biome shell: a layer of land-colored tiles over the base (ocean) sphere, laid
-- at the LOD radius (just under the surface, so streamed terrain covers them up close).
-- Oceans are left to the base sphere, so only land cells become tiles.
function PlanetRenderer:_buildBiomeShell()
	local folder = Instance.new("Folder")
	folder.Name = "BiomeShell"
	self._shell = folder
	self._shellVisible = false

	local R = self._trueRadius
	local Nlat = Config.LOD.latBands
	local lonBands = Config.LOD.lonBands
	local cellH = (math.pi * R) / Nlat
	for i = 0, Nlat - 1 do
		local lat = -math.pi / 2 + (i + 0.5) * (math.pi / Nlat)
		local cl, sl = math.cos(lat), math.sin(lat)
		local Nlon = math.max(3, math.floor(lonBands * cl + 0.5))
		local cellW = (2 * math.pi * R * cl) / Nlon
		for j = 0, Nlon - 1 do
			local lon = (j + 0.5) * (2 * math.pi / Nlon)
			local dx, dy, dz = cl * math.cos(lon), sl, cl * math.sin(lon)
			if not Planet.isOceanUnit(dx, dy, dz) then
				local dir = Vector3.new(dx, dy, dz)
				local tile = Instance.new("Part")
				tile.Anchored = true
				tile.CanCollide = false
				tile.CanQuery = false
				tile.CanTouch = false
				tile.CastShadow = false
				tile.Size = Vector3.new(cellW * 1.5 + 6, 2, cellH * 1.5 + 6)
				tile.Color = Planet.lodColorForUnit(dx, dy, dz)
				tile.Material = Enum.Material.SmoothPlastic
				tile.CFrame = frameFromUp(dir * (R + 3), dir)
				tile.Parent = folder
			end
		end
	end
end

function PlanetRenderer:_setShell(visible)
	if visible ~= self._shellVisible then
		self._shellVisible = visible
		self._shell.Parent = visible and Workspace or nil
	end
end

function PlanetRenderer:_update()
	local cam = Workspace.CurrentCamera
	if not cam or not self._ball then
		return
	end

	-- Map view draws its own compressed body (MapViewController); hide the real one.
	if self._input:GetMapMode() then
		if self._ball.Transparency ~= 1 then
			self._ball.Transparency = 1
			self._atmo.Transparency = 1
		end
		self:_setShell(false)
		return
	elseif self._ball.Transparency ~= 0 then
		self._ball.Transparency = 0
		self._atmo.Transparency = 0.5
	end

	local center = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local camPos = cam.CFrame.Position
	local toPlanet = center - camPos
	local dist = toPlanet.Magnitude

	-- Show the biome tiles only within render range (in orbit, where you'd see them); far
	-- out the planet is just a dot, so fall back to the plain ocean sphere.
	self:_setShell(dist <= self._maxRender)

	local renderCenter, scale
	if dist <= self._maxRender or dist < 1e-3 then
		-- Within range: draw at true scale and position; terrain aligns with it.
		renderCenter = center
		scale = 1
	else
		-- Pull the far body into render range, preserving its angular size.
		scale = self._maxRender / dist
		renderCenter = camPos + toPlanet.Unit * self._maxRender
	end

	self:_apply(self._ballMesh, self._ball, self._trueRadius * 2 * scale, renderCenter)
	if self._atmo then
		self:_apply(self._atmoMesh, self._atmo, self._atmoRadius * 2 * scale, renderCenter)
	end
end

return PlanetRenderer
