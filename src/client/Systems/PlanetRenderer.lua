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

	Biome detail (continents/deserts/ice) is laid over the base ocean sphere as a shell
	of flat land-coloured tiles, shown only from space (terrain covers it up close).
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))
local RenderScale = require(Shared:WaitForChild("RenderScale"))

local PlanetRenderer = {}

-- Part collision-box size for the mesh spheres.
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
	self._surfaceRadius = Config.BODY.radius
	-- Cosmetic atmosphere: a thin limb only (kept close to the surface, gone below ~4k alt).
	self._atmoRadius = Config.BODY.radius + math.min(Config.ATMOSPHERE.top, 1800)
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

	self._ball, self._ballMesh =
		self:_makeSphere("Planet", Config.BODY.lodColor or Config.BODY.grassColor, Enum.Material.SmoothPlastic, 0)
	-- Translucent atmosphere shell (purely cosmetic), drawn concentric with the body.
	self._atmo, self._atmoMesh = self:_makeSphere("Atmosphere", Config.ATMOSPHERE.color, Enum.Material.ForceField, 0.8)

	self:_buildBiomeShell()

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

-- Build the biome shell: a layer of land-coloured tiles over the base (ocean) sphere, laid
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
	if not self._shell then
		return
	end
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
		self._atmo.Transparency = 0.8
	end

	local center = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local camPos = cam.CFrame.Position
	local toPlanet = center - camPos
	local dist = toPlanet.Magnitude

	-- Show the biome tiles only from SPACE -- high enough that terrain has unloaded (so they
	-- never poke through the ground) and only while the body is drawn at TRUE scale (within
	-- nearDist); past that it's compressed to a dot and the tiles would no longer align.
	local fromSpace = dist > (self._surfaceRadius + Config.TERRAIN.streamOutAlt)
	self:_setShell(fromSpace and dist <= Config.RENDER.nearDist)

	-- Depth-correct pull-in (shared with Moon/Sun so occlusion is right).
	local rd, scale = RenderScale.pull(dist, Config.RENDER.nearDist, Config.RENDER.maxDist)
	local renderCenter = (dist < 1e-3) and center or (camPos + toPlanet.Unit * rd)

	self:_apply(self._ballMesh, self._ball, self._trueRadius * 2 * scale, renderCenter)
	if self._atmo then
		self:_apply(self._atmoMesh, self._atmo, self._atmoRadius * 2 * scale, renderCenter)
	end
end

return PlanetRenderer
