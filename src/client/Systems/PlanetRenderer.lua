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

-- Hermite smoothstep, for the baked day/night terminator.
local function smoothstep(e0, e1, x)
	if e0 == e1 then
		return x >= e1 and 1 or 0
	end
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

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
	self._atmoRadius = Config.BODY.radius + Config.ATMOSPHERE.top
	-- A second, larger atmosphere shell for a soft outer limb glow (the scattering halo).
	self._glowRadius = self._atmoRadius * 1.08
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

	-- The body is drawn Neon (self-lit): the space sky keeps the sun down for stars, so the
	-- planet can't be lit conventionally -- instead it shows its baked albedo + terminator
	-- directly. A dark ocean-blue base sits under the biome shell as the smooth round limb.
	self._ball, self._ballMesh = self:_makeSphere("Planet", Color3.fromRGB(20, 42, 70), Enum.Material.Neon, 0)
	-- Two concentric ForceField shells (brightest at the silhouette) fake the atmospheric
	-- scattering halo: an inner haze and a softer, larger outer glow.
	self._atmo, self._atmoMesh = self:_makeSphere("Atmosphere", Config.ATMOSPHERE.color, Enum.Material.ForceField, 0.55)
	self._glow, self._glowMesh = self:_makeSphere(
		"AtmoGlow",
		Config.ATMOSPHERE.color:Lerp(Color3.new(1, 1, 1), 0.3),
		Enum.Material.ForceField,
		0.85
	)

	-- Biome detail over the base (ocean) sphere, so you see continents from orbit. Prefer a
	-- painted equirectangular texture; fall back to a tile shell if that isn't supported.
	if not self:_tryTexture() then
		self:_buildBiomeShell()
	end

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

-- Build the biome shell: a full-sphere layer of Neon (self-lit) tiles over the dark base
-- sphere, laid at the LOD radius (just under the surface, so streamed terrain covers them
-- up close). Each tile's colour is the biome ALBEDO with the day/night terminator and an
-- ocean sun-glint BAKED in for a fixed space-sun direction -- the planet keeps a lit limb
-- and a dark night side against the stars, at zero per-frame cost.
function PlanetRenderer:_buildBiomeShell()
	local folder = Instance.new("Folder")
	folder.Name = "BiomeShell"
	self._shell = folder
	self._shellVisible = false

	local L = Config.LOD
	local sun = (L.sunDir and L.sunDir.Magnitude > 1e-3) and L.sunDir.Unit or Vector3.new(0.55, 0.5, -0.66).Unit
	local night = L.nightShade or 0.16
	local soft = L.termSoftness or 0.30
	local tint = L.nightTint or Color3.fromRGB(16, 24, 42)
	local oceanSpec = L.oceanSpec or 0.55
	local specTight = L.oceanSpecTight or 64

	local R = self._trueRadius
	local Nlat = L.latBands
	local lonBands = L.lonBands
	local cellH = (math.pi * R) / Nlat
	for i = 0, Nlat - 1 do
		local lat = -math.pi / 2 + (i + 0.5) * (math.pi / Nlat)
		local cl, sl = math.cos(lat), math.sin(lat)
		local Nlon = math.max(3, math.floor(lonBands * cl + 0.5))
		local cellW = (2 * math.pi * R * cl) / Nlon
		for j = 0, Nlon - 1 do
			local lon = (j + 0.5) * (2 * math.pi / Nlon)
			local dx, dy, dz = cl * math.cos(lon), sl, cl * math.sin(lon)
			local dir = Vector3.new(dx, dy, dz)
			local albedo = Planet.lodColorForUnit(dx, dy, dz)

			-- Baked terminator: brightness from the sun-facing dot, softened across the
			-- day/night line, with a cool tint over the shadowed hemisphere.
			local dd = dir:Dot(sun)
			local lit = smoothstep(-soft, soft, dd)
			local b = night + (1 - night) * lit
			local c = Color3.new(albedo.R * b, albedo.G * b, albedo.B * b):Lerp(tint, (1 - lit) * 0.5)
			-- Ocean sun-glint: a tight specular hotspot near the sub-solar point.
			if dd > 0 and Planet.isOceanUnit(dx, dy, dz) then
				local s = (dd ^ specTight) * oceanSpec * lit
				c = Color3.new(math.min(c.R + s * 0.9, 1), math.min(c.G + s * 0.95, 1), math.min(c.B + s, 1))
			end

			local tile = Instance.new("Part")
			tile.Anchored = true
			tile.CanCollide = false
			tile.CanQuery = false
			tile.CanTouch = false
			tile.CastShadow = false
			tile.Size = Vector3.new(cellW * 1.7 + 6, 2, cellH * 1.7 + 6)
			tile.Color = c
			tile.Material = Enum.Material.Neon
			tile.CFrame = frameFromUp(dir * (R + 3), dir)
			tile.Parent = folder
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

-- Try to paint an equirectangular biome image (sampled from Planet) onto the LOD sphere
-- via EditableImage. The sphere is at the LOD radius (below the surface), so it never
-- pokes through terrain. Returns true if it applied; on any failure returns false so we
-- fall back to the tile shell. (Roblox's sphere-mesh texturing is finicky and this can't
-- be verified here, so it's behind Config.LOD.smoothTexture and fully pcall-guarded.)
function PlanetRenderer:_tryTexture()
	if not Config.LOD.smoothTexture then
		return false
	end
	local AssetService = game:GetService("AssetService")
	local ok = pcall(function()
		local W = math.clamp(Config.LOD.textureSize or 256, 16, 1024)
		local H = math.max(8, math.floor(W / 2))
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
		if not img then
			error("EditableImage unavailable")
		end
		local buf = buffer.create(W * H * 4)
		local i = 0
		for y = 0, H - 1 do
			local lat = (0.5 - (y + 0.5) / H) * math.pi -- +pi/2 (top) .. -pi/2 (bottom)
			local cl, sl = math.cos(lat), math.sin(lat)
			for x = 0, W - 1 do
				local lon = ((x + 0.5) / W * 2 - 1) * math.pi
				local c = Planet.lodColorForUnit(cl * math.cos(lon), sl, cl * math.sin(lon))
				buffer.writeu8(buf, i, math.floor(c.R * 255 + 0.5))
				buffer.writeu8(buf, i + 1, math.floor(c.G * 255 + 0.5))
				buffer.writeu8(buf, i + 2, math.floor(c.B * 255 + 0.5))
				buffer.writeu8(buf, i + 3, 255)
				i += 4
			end
		end
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), buf)
		self._ballMesh.TextureId = Content.fromObject(img)
	end)
	self._textured = ok
	return ok
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
			self._glow.Transparency = 1
		end
		self:_setShell(false)
		return
	elseif self._ball.Transparency ~= 0 then
		self._ball.Transparency = 0
		self._atmo.Transparency = 0.55
		self._glow.Transparency = 0.85
	end

	local center = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local camPos = cam.CFrame.Position
	local toPlanet = center - camPos
	local dist = toPlanet.Magnitude

	-- Show the biome tiles only from SPACE -- high enough that terrain has unloaded (so they
	-- never poke through the ground) and still within render range (far out it's just a dot).
	local fromSpace = dist > (self._surfaceRadius + Config.TERRAIN.streamOutAlt)
	self:_setShell(not self._textured and fromSpace and dist <= self._maxRender)

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
	if self._glow then
		self:_apply(self._glowMesh, self._glow, self._glowRadius * 2 * scale, renderCenter)
	end
end

return PlanetRenderer
