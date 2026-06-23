--[[
	MapViewController
	Owner of: the orbit line + exact apo/peri/craft markers in map view.

	Map view is drawn TO SCALE: the body (CraftRenderer's MapPlanet) is the real
	surface size at mapScale, so an orbit that clears the drawn planet clears the
	real surface. Apoapsis / periapsis are computed exactly from the orbital
	elements (not sampled), labelled with their altitudes, and the periapsis goes
	red when it dips below the surface (impact warning).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local MapViewController = {}

local function mag(v)
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function fmtAlt(n)
	if n == math.huge then
		return "inf"
	end
	if math.abs(n) >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return string.format("%.0f", n)
end

function MapViewController:Init()
	self._segments = {}
	self._visible = false
	self._needRecompute = true
	self._frame = 0
end

function MapViewController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")
	local Flight = Registry:Get("FlightController")
	self._mu = Flight:GetMu()
	self._bodyRadius = Flight:GetBodyRadius()

	self:_buildPool()
	self:_setVisible(self._input:GetMapMode())

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

local function markerLabel(part, text)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(90, 18)
	bb.StudsOffset = Vector3.new(0, 1.4, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = part
	bb.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Code
	lbl.TextSize = 14
	lbl.TextStrokeTransparency = 0.4
	lbl.TextColor3 = part.Color
	lbl.Text = text
	lbl.Parent = bb
	return lbl
end

function MapViewController:_buildPool()
	local cfg = Config.ORBITLINE
	local folder = Instance.new("Folder")
	folder.Name = "OrbitPath"
	folder.Parent = Workspace
	self._folder = folder

	local function newPart(color, shape)
		local p = Instance.new("Part")
		if shape then
			p.Shape = shape
		end
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Size = Vector3.new(10, 10, 10)
		p.Parent = folder
		return p
	end

	self._segColor = cfg.color
	self._dangerColor = Color3.fromRGB(255, 70, 70)
	for i = 1, cfg.segments do
		self._segments[i] = newPart(cfg.color)
	end
	self._apoMarker = newPart(cfg.apoColor, Enum.PartType.Ball)
	self._periMarker = newPart(cfg.periColor, Enum.PartType.Ball)
	self._craftMarker = newPart(cfg.craftColor, Enum.PartType.Ball)
	self._apoLabel = markerLabel(self._apoMarker, "Ap")
	self._periLabel = markerLabel(self._periMarker, "Pe")
	markerLabel(self._craftMarker, "CRAFT")

	-- Compressed body for the map (mesh sphere so it can be any size). Sized + placed
	-- each frame; only shown in map view.
	local planet = Instance.new("Part")
	planet.Name = "MapPlanet"
	planet.Anchored = true
	planet.CanCollide = false
	planet.CanQuery = false
	planet.CanTouch = false
	planet.CastShadow = false
	planet.Size = Vector3.new(2048, 2048, 2048)
	planet.Color = Config.BODY.lodColor or Config.BODY.grassColor
	planet.Material = Enum.Material.SmoothPlastic
	planet.Parent = folder
	local pmesh = Instance.new("SpecialMesh")
	pmesh.MeshType = Enum.MeshType.Sphere
	pmesh.Parent = planet
	self._mapPlanet = planet
	self._mapPlanetMesh = pmesh

	-- The moon: a body sphere + a dashed orbit ring, shown (relative to Terra) while you
	-- are in Terra's SOI so you can aim a transfer at it.
	local moon = Instance.new("Part")
	moon.Name = "MapMoon"
	moon.Anchored = true
	moon.CanCollide = false
	moon.CanQuery = false
	moon.CanTouch = false
	moon.CastShadow = false
	moon.Shape = Enum.PartType.Ball
	moon.Material = Enum.Material.SmoothPlastic
	moon.Color = Config.MOON.color
	moon.Size = Vector3.new(10, 10, 10)
	moon.Parent = folder
	self._moonMarker = moon
	self._secondaryLabel = markerLabel(moon, Config.MOON.name)

	self._moonRing = {}
	for i = 1, 48 do
		self._moonRing[i] = newPart(Color3.fromRGB(120, 124, 140))
	end
	-- Unit circle in the X/Z plane (the moon's equatorial orbit plane); scaled by radius.
	self._unitCircle = {}
	for i = 0, 48 do
		local a = (i / 48) * 2 * math.pi
		self._unitCircle[i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
	end
end

function MapViewController:_setVisible(v)
	self._visible = v
	for _, seg in ipairs(self._segments) do
		seg.Transparency = v and 0 or 1
	end
	self._apoMarker.Transparency = v and 0 or 1
	self._periMarker.Transparency = v and 0 or 1
	self._craftMarker.Transparency = v and 0 or 1
	self._mapPlanet.Transparency = v and 0 or 1
	if not v then
		self._moonMarker.Transparency = 1
		for _, seg in ipairs(self._moonRing) do
			seg.Transparency = 1
		end
	end
end

function MapViewController:_recompute(state, mu)
	mu = mu or self._mu
	self._simPath = Orbit.sampleOrbitPath(state, mu, Config.ORBITLINE.segments)

	-- Exact orbital geometry from state (eccentricity vector points to periapsis).
	local pos, vel = state.position, state.velocity
	local r = mag(pos)
	local speed = mag(vel)
	local rv = pos.x * vel.x + pos.y * vel.y + pos.z * vel.z
	local coef = speed * speed - mu / r
	local ex = (coef * pos.x - rv * vel.x) / mu
	local ey = (coef * pos.y - rv * vel.y) / mu
	local ez = (coef * pos.z - rv * vel.z) / mu
	local e = math.sqrt(ex * ex + ey * ey + ez * ez)
	local ro = Orbit.getReadout(state, mu) -- radii
	local peR = ro.periapsis
	local apoR = ro.apoapsis

	local peDir
	if e > 1e-6 then
		peDir = Vector3.new(ex, ey, ez) / e
	else
		peDir = Vector3.new(pos.x, pos.y, pos.z)
		peDir = (peDir.Magnitude > 1e-6) and peDir.Unit or Vector3.xAxis
	end

	self._pePoint = peDir * peR
	self._peR = peR
	self._apoPoint = (apoR < math.huge) and (-peDir * apoR) or nil
	self._apoR = apoR
end

-- Draw the "other" body (and its orbit ring) relative to the active body, so you can aim
-- a transfer at it: the Mun (relative to Terra) while in Terra's SOI, or Terra (relative to
-- the Sun) while in solar orbit. Hidden in the moon's SOI.
function MapViewController:_drawSecondary(info, focus, s, mk)
	local center, drawRadius, color, label
	if info.bodyId == "planet" and info.moonCenter then
		center, drawRadius, color, label = info.moonCenter, info.moonRadius, Config.MOON.color, Config.MOON.name
	elseif info.bodyId == "sun" and info.terraCenter then
		center, drawRadius, color, label =
			info.terraCenter, Config.BODY.radius, (Config.BODY.lodColor or Config.BODY.grassColor), Config.BODY.name
	end
	if not center then
		self._moonMarker.Transparency = 1
		for _, seg in ipairs(self._moonRing) do
			seg.Transparency = 1
		end
		return
	end

	self._moonMarker.Transparency = 0
	self._moonMarker.Color = color
	self._secondaryLabel.Text = label
	self._secondaryLabel.TextColor3 = color
	local md = math.max((drawRadius or 0) * s * 2, mk * 1.4)
	self._moonMarker.Size = Vector3.new(md, md, md)
	self._moonMarker.CFrame = CFrame.new(focus + Vector3.new(center.x, center.y, center.z) * s)

	local radius = mag(center)
	local ringThick = math.max((info.bodyRadius or 1) * s * 0.02, 0.05)
	local prev
	for i = 1, #self._unitCircle do
		local pt = focus + (self._unitCircle[i] * radius) * s
		if prev then
			local seg = self._moonRing[i - 1]
			local len = (pt - prev).Magnitude
			if len < 1e-3 then
				seg.Transparency = 1
			else
				seg.Transparency = 0.4
				seg.Size = Vector3.new(ringThick, ringThick, len)
				seg.CFrame = CFrame.lookAt((pt + prev) * 0.5, pt)
			end
		end
		prev = pt
	end
end

function MapViewController:_update(state, info)
	if not (info and info.mapMode) then
		if self._visible then
			self:_setVisible(false)
		end
		return
	elseif not self._visible then
		self:_setVisible(true)
		self._needRecompute = true
	end

	-- The map is centred on (and scaled to) the ACTIVE body -- so it follows you into the
	-- moon's SOI automatically.
	local mu = info.mu or self._mu
	local R = info.bodyRadius or self._bodyRadius

	self._frame += 1
	if (info and info.powered) or self._frame % 15 == 0 then
		self._needRecompute = true
	end
	if self._needRecompute or not self._simPath then
		self:_recompute(state, mu)
		self._needRecompute = false
	end

	-- The map is a SCHEMATIC: draw it at the world origin regardless of where the active
	-- body actually is (in solar orbit bodyCenter is ~900k studs out -- too far to render).
	-- Everything (orbit, markers, the secondary body) is positioned relative to this focus.
	local focus = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local s = info.mapScale or 1
	local function projVec(v)
		return focus + v * s
	end
	local function projSim(sp)
		return focus + Vector3.new(sp.x, sp.y, sp.z) * s
	end
	local thickness = R * s * 0.03
	local mk = R * s * 0.08

	-- Compressed body sphere at the focus (the active body, sized to its radius).
	local pd = R * s * 2
	local psc = pd / 2048
	self._mapPlanetMesh.Scale = Vector3.new(psc, psc, psc)
	local focusColor = Config.BODY.lodColor or Config.BODY.grassColor
	if info.bodyId == "moon" then
		focusColor = Config.MOON.color
	elseif info.bodyId == "sun" then
		focusColor = Config.SUN.color
	end
	self._mapPlanet.Color = focusColor
	self._mapPlanet.CFrame = CFrame.new(focus)

	-- The other body (Mun in Terra's SOI, or Terra in solar orbit), so you can aim back.
	self:_drawSecondary(info, focus, s, mk)

	-- Orbit line; segments below the surface go red (impact warning).
	local pts = self._simPath
	local n = #pts
	local render = table.create(n)
	for i = 1, n do
		render[i] = projSim(pts[i])
	end
	for i = 1, #self._segments do
		local a, b = render[i], render[i + 1]
		local seg = self._segments[i]
		if not b then
			seg.Transparency = 1
		else
			local len = (b - a).Magnitude
			if len < 1e-3 then
				seg.Transparency = 1
			else
				seg.Transparency = 0
				seg.Size = Vector3.new(thickness, thickness, len)
				seg.CFrame = CFrame.lookAt((a + b) * 0.5, b)
				local belowSurface = (mag(pts[i]) < R) or (mag(pts[i + 1]) < R)
				seg.Color = belowSurface and self._dangerColor or self._segColor
			end
		end
	end

	-- Craft marker.
	self._craftMarker.Transparency = 0
	self._craftMarker.Size = Vector3.new(mk, mk, mk)
	self._craftMarker.CFrame = CFrame.new(projSim(state.position))

	-- Exact periapsis (red if it impacts) + apoapsis, with altitude labels.
	self._periMarker.Transparency = 0
	self._periMarker.Size = Vector3.new(mk, mk, mk)
	self._periMarker.CFrame = CFrame.new(projVec(self._pePoint))
	local impact = self._peR < R
	self._periMarker.Color = impact and self._dangerColor or Config.ORBITLINE.periColor
	self._periLabel.TextColor3 = self._periMarker.Color
	self._periLabel.Text = (impact and "IMPACT " or "Pe ") .. fmtAlt(self._peR - R)

	if self._apoPoint then
		self._apoMarker.Transparency = 0
		self._apoMarker.Size = Vector3.new(mk, mk, mk)
		self._apoMarker.CFrame = CFrame.new(projVec(self._apoPoint))
		self._apoLabel.Text = "Ap " .. fmtAlt(self._apoR - R)
	else
		self._apoMarker.Transparency = 1
	end
end

return MapViewController
