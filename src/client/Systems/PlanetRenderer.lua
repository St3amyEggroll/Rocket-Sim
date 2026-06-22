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
local BiomeSphere = require(Shared:WaitForChild("BiomeSphere"))

local PlanetRenderer = {}

-- LOD biome-tile + cloud detail (Low setting). Grids kept coarse for performance.
local TILE_LAT, TILE_LON = 16, 32
local CLOUD_LAT, CLOUD_LON = 14, 28
local CLOUD_HEIGHT = 150 -- studs above sea level for the cloud layer
local CLOUD_SPIN = 0.015 -- rad/s drift

-- Part collision-box size for the mesh spheres: as large as the part cap allows, so
-- the body resists distance-culling out to low orbit. The visible size is driven
-- entirely by mesh.Scale = renderedDiameter / BASE.
local BASE = 2048

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

	-- Base ocean sphere (continents are drawn on top as biome tiles).
	self._ball, self._ballMesh = self:_makeSphere("Planet", Config.BODY.lodColor or Config.BODY.grassColor, Enum.Material.SmoothPlastic, 0)
	-- Translucent atmosphere shell (purely cosmetic), drawn concentric with the body.
	self._atmo, self._atmoMesh = self:_makeSphere("Atmosphere", Config.ATMOSPHERE.color, Enum.Material.ForceField, 0.55)

	-- Biome land tiles + cloud layer, drawn at true scale at the origin and shown only
	-- when reasonably close (within maxRender); far away the plain ocean ball stands in.
	self._tiles = BiomeSphere.buildTiles(self._trueRadius, TILE_LAT, TILE_LON)
	self._tiles.Parent = nil
	self._clouds = self:_buildClouds()
	self._clouds.Parent = nil
	self._detailOn = false

	-- Update after the camera has been positioned for this frame.
	RunService:BindToRenderStep("RocketSim_Planet", Enum.RenderPriority.Camera.Value + 2, function()
		self:_update()
	end)
end

function PlanetRenderer:_buildClouds()
	local model = Instance.new("Model")
	model.Name = "Clouds"
	local anchor = Instance.new("Part")
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(0, 0, 0)
	anchor.Parent = model
	model.PrimaryPart = anchor

	local radius = Config.BODY.radius + CLOUD_HEIGHT
	local latArc = radius * (math.pi / CLOUD_LAT)
	for i = 0, CLOUD_LAT - 1 do
		local theta = (i + 0.5) / CLOUD_LAT * math.pi
		local st, ct = math.sin(theta), math.cos(theta)
		for j = 0, CLOUD_LON - 1 do
			local phi = (j + 0.5) / CLOUD_LON * 2 * math.pi
			local sp, cp = math.sin(phi), math.cos(phi)
			local dir = Vector3.new(st * cp, ct, st * sp)
			if Planet.cloudAt(dir.X, dir.Y, dir.Z) > Config.BIOMES.cloudCover then
				local lonArc = math.max(radius * st * (2 * math.pi / CLOUD_LON), latArc * 0.5)
				local east = Vector3.new(-sp, 0, cp)
				local tile = Instance.new("Part")
				tile.Anchored = true
				tile.CanCollide = false
				tile.CanQuery = false
				tile.CanTouch = false
				tile.CastShadow = false
				tile.Material = Enum.Material.SmoothPlastic
				tile.Color = Color3.fromRGB(245, 248, 252)
				tile.Transparency = 0.35
				tile.Size = Vector3.new(lonArc * 1.25, 2, latArc * 1.25)
				tile.CFrame = CFrame.fromMatrix(dir * radius, east, dir)
				tile.Parent = model
			end
		end
	end
	return model
end

-- Size a mesh sphere to a rendered DIAMETER and place its centre.
function PlanetRenderer:_apply(mesh, part, diameter, center)
	local s = diameter / BASE
	mesh.Scale = Vector3.new(s, s, s)
	part.CFrame = CFrame.new(center)
end

function PlanetRenderer:_setDetail(on)
	if on == self._detailOn then
		return
	end
	self._detailOn = on
	self._tiles.Parent = on and Workspace or nil
	self._clouds.Parent = on and Workspace or nil
end

function PlanetRenderer:_update()
	local cam = Workspace.CurrentCamera
	if not cam or not self._ball then
		return
	end

	local center = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local camPos = cam.CFrame.Position
	local toPlanet = center - camPos
	local dist = toPlanet.Magnitude

	-- Map view draws its own compressed body (MapViewController); hide the real one.
	if self._input:GetMapMode() then
		self:_setDetail(false)
		if self._ball.Transparency ~= 1 then
			self._ball.Transparency = 1
			self._atmo.Transparency = 1
		end
		return
	elseif self._ball.Transparency ~= 0 then
		self._ball.Transparency = 0
		self._atmo.Transparency = 0.55
	end

	local renderCenter, scale
	if dist <= self._maxRender or dist < 1e-3 then
		-- Within range: draw at true scale and position; terrain aligns with it.
		renderCenter = center
		scale = 1
		self:_setDetail(true)
		self._tiles:PivotTo(CFrame.new(center))
		self._clouds:PivotTo(CFrame.new(center) * CFrame.Angles(0, os.clock() * CLOUD_SPIN, 0))
	else
		-- Pull the far body into render range, preserving its angular size.
		scale = self._maxRender / dist
		renderCenter = camPos + toPlanet.Unit * self._maxRender
		self:_setDetail(false) -- too far for tiles; the plain ball stands in
	end

	self:_apply(self._ballMesh, self._ball, self._trueRadius * 2 * scale, renderCenter)
	if self._atmo then
		self:_apply(self._atmoMesh, self._atmo, self._atmoRadius * 2 * scale, renderCenter)
	end
end

return PlanetRenderer
