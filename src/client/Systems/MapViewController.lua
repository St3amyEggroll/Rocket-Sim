--[[
	MapViewController
	Owner of: the map schematic -- the craft's orbit, apo/peri/craft markers, and the
	whole Sun -> Terra -> Mun hierarchy with their orbit rings.

	The schematic is drawn at the LITERAL world origin (independent of the floating origin,
	which in deep space follows the craft) and viewed by a fixed, render-safe camera. ZOOM
	scales the CONTENT (a view radius in sim units mapped to a fixed render frame) instead of
	moving the camera -- so you can zoom from a tight local orbit all the way out to Terra
	circling the Sun without ever pushing anything past the draw range.

	Everything is drawn in the ACTIVE body's frame (the active body sits at the centre); the
	other bodies and rings are placed by their position relative to it. Apo/peri are computed
	exactly from the orbital elements; periapsis goes red when it dips below the surface.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local MapViewController = {}

local RING_SEGS = 48

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

	-- Compressed body for the map (mesh sphere so it can be any size): the ACTIVE body, at
	-- the centre. Sized + coloured each frame; only shown in map view.
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

	-- The other bodies (the non-active ones get a marker each).
	local function newBody(color, name)
		local p = newPart(color, Enum.PartType.Ball)
		p.Material = Enum.Material.SmoothPlastic
		local lbl = markerLabel(p, name)
		return { marker = p, label = lbl }
	end
	self._sun = newBody(Config.SUN.color, Config.SUN.name)
	self._terra = newBody(Config.BODY.lodColor or Config.BODY.grassColor, Config.BODY.name)
	self._mun = newBody(Config.MOON.color, Config.MOON.name)

	-- Orbit rings: the Mun's around Terra, and Terra's around the Sun.
	local function newRing(color)
		local r = {}
		for i = 1, RING_SEGS do
			r[i] = newPart(color)
		end
		return r
	end
	self._munRing = newRing(Color3.fromRGB(120, 124, 140))
	self._terraRing = newRing(Color3.fromRGB(150, 148, 116))

	-- Unit circle in the X/Z plane (the equatorial orbit plane); scaled by radius.
	self._unitCircle = {}
	for i = 0, RING_SEGS do
		local a = (i / RING_SEGS) * 2 * math.pi
		self._unitCircle[i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
	end
end

function MapViewController:_hideAll()
	for _, seg in ipairs(self._segments) do
		seg.Transparency = 1
	end
	self._apoMarker.Transparency = 1
	self._periMarker.Transparency = 1
	self._craftMarker.Transparency = 1
	self._mapPlanet.Transparency = 1
	for _, b in ipairs({ self._sun, self._terra, self._mun }) do
		b.marker.Transparency = 1
		b.label.Parent.Enabled = false
	end
	for _, ring in ipairs({ self._munRing, self._terraRing }) do
		for _, seg in ipairs(ring) do
			seg.Transparency = 1
		end
	end
end

function MapViewController:_setVisible(v)
	self._visible = v
	if not v then
		self:_hideAll()
	else
		self._mapPlanet.Transparency = 0
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

-- Draw a non-active body marker at its in-frame position (scaled), or hide it (it's the
-- centre body, or off the schematic).
function MapViewController:_drawBody(b, posV, realRadius, isActive, s, mk, cutoff, focus)
	if isActive or posV.Magnitude > cutoff then
		b.marker.Transparency = 1
		b.label.Parent.Enabled = false
		return
	end
	b.marker.Transparency = 0
	b.label.Parent.Enabled = true
	local d = math.max(realRadius * s * 2, mk * 1.5)
	b.marker.Size = Vector3.new(d, d, d)
	b.marker.CFrame = CFrame.new(focus + posV)
end

-- Draw an orbit ring (a body's path) centred at `centerV` (in-frame, unscaled) with `radius`
-- (sim units), scaled to render space. Segments off the schematic are hidden.
function MapViewController:_drawRing(ring, centerV, radius, s, color, thick, cutoff, focus)
	local prev
	for i = 1, #self._unitCircle do
		local p = (centerV + self._unitCircle[i] * radius) * s -- in-frame render offset
		local rp = focus + p
		if prev then
			local seg = ring[i - 1]
			local len = (rp - prev).Magnitude
			local mid = (rp + prev) * 0.5
			if len < 1e-3 or (mid - focus).Magnitude > cutoff then
				seg.Transparency = 1
			else
				seg.Transparency = 0.45
				seg.Color = color
				seg.Size = Vector3.new(thick, thick, len)
				seg.CFrame = CFrame.lookAt(mid, rp)
			end
		end
		prev = rp
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

	local mu = info.mu or self._mu
	local R = info.bodyRadius or self._bodyRadius

	self._frame += 1
	if info.powered or self._frame % 15 == 0 then
		self._needRecompute = true
	end
	if self._needRecompute or not self._simPath then
		self:_recompute(state, mu)
		self._needRecompute = false
	end

	local F = Config.MAP.frameSize
	local focus = Vector3.zero

	-- Content scale from zoom: a view radius (sim units) mapped to the fixed render frame.
	-- Zoom out -> bigger viewR -> smaller schematic -> more of the system on screen.
	local rNow = mag(state.position)
	local apoR = (self._apoR and self._apoR < math.huge) and self._apoR or rNow
	local baseViewR = math.max(apoR, rNow, R * 1.5)
	local mapZoom = self._input:GetCameraOrbit().mapZoom or 1
	local viewR = math.clamp(baseViewR * mapZoom, R * 1.2, Config.SUN.orbitRadius * 1.6)
	local s = F / viewR
	-- Hide content past the framed region so nothing is drawn beyond the camera's draw range.
	local cutoff = F * 1.1
	local segThick = F * 0.0045
	local mk = F * 0.013

	local bc = info.bodyCenter or Orbit.vec(0, 0, 0)
	local bcv = Vector3.new(bc.x, bc.y, bc.z)
	local function inFrame(tc)
		return Vector3.new(tc.x, tc.y, tc.z) - bcv
	end
	local function rend(v)
		return focus + v * s
	end

	local activeId = info.bodyId

	-- Active body sphere at the centre.
	local pd = math.max(R * s * 2, F * 0.022)
	local psc = pd / 2048
	self._mapPlanetMesh.Scale = Vector3.new(psc, psc, psc)
	local focusColor = Config.BODY.lodColor or Config.BODY.grassColor
	if activeId == "moon" then
		focusColor = Config.MOON.color
	elseif activeId == "sun" then
		focusColor = Config.SUN.color
	end
	self._mapPlanet.Transparency = 0
	self._mapPlanet.Color = focusColor
	self._mapPlanet.CFrame = CFrame.new(focus)

	-- The other bodies (Terra-centric positions; the active one is hidden -- it's the centre).
	local terraTC, munTC, sunTC = Orbit.vec(0, 0, 0), info.moonCenter, info.sunCenter
	self:_drawBody(self._sun, inFrame(sunTC) * s, Config.SUN.radius, activeId == "sun", s, mk, cutoff, focus)
	self:_drawBody(self._terra, inFrame(terraTC) * s, Config.BODY.radius, activeId == "planet", s, mk, cutoff, focus)
	self:_drawBody(self._mun, inFrame(munTC) * s, Config.MOON.radius, activeId == "moon", s, mk, cutoff, focus)

	-- Orbit rings: the Mun around Terra, Terra around the Sun.
	self:_drawRing(self._munRing, inFrame(terraTC), Config.MOON.orbitRadius, s, Color3.fromRGB(120, 124, 140), segThick, cutoff, focus)
	self:_drawRing(self._terraRing, inFrame(sunTC), Config.SUN.orbitRadius, s, Color3.fromRGB(150, 148, 116), segThick, cutoff, focus)

	-- Craft orbit (relative to the active body == the centre).
	local pts = self._simPath
	for i = 1, #self._segments do
		local seg = self._segments[i]
		local a, b = pts[i], pts[i + 1]
		if not b then
			seg.Transparency = 1
		else
			local ra = rend(Vector3.new(a.x, a.y, a.z))
			local rb = rend(Vector3.new(b.x, b.y, b.z))
			local len = (rb - ra).Magnitude
			local mid = (ra + rb) * 0.5
			if len < 1e-3 or (mid - focus).Magnitude > cutoff then
				seg.Transparency = 1
			else
				seg.Transparency = 0
				seg.Size = Vector3.new(segThick, segThick, len)
				seg.CFrame = CFrame.lookAt(mid, rb)
				local below = (mag(a) < R) or (mag(b) < R)
				seg.Color = below and self._dangerColor or self._segColor
			end
		end
	end

	-- Craft marker.
	self._craftMarker.Transparency = 0
	self._craftMarker.Size = Vector3.new(mk, mk, mk)
	self._craftMarker.CFrame = CFrame.new(rend(Vector3.new(state.position.x, state.position.y, state.position.z)))

	-- Exact periapsis (red if it impacts) + apoapsis, with altitude labels.
	self._periMarker.Transparency = 0
	self._periMarker.Size = Vector3.new(mk, mk, mk)
	self._periMarker.CFrame = CFrame.new(rend(self._pePoint))
	local impact = self._peR < R
	self._periMarker.Color = impact and self._dangerColor or Config.ORBITLINE.periColor
	self._periLabel.TextColor3 = self._periMarker.Color
	self._periLabel.Text = (impact and "IMPACT " or "Pe ") .. fmtAlt(self._peR - R)

	if self._apoPoint then
		self._apoMarker.Transparency = 0
		self._apoLabel.Parent.Enabled = true
		self._apoMarker.Size = Vector3.new(mk, mk, mk)
		self._apoMarker.CFrame = CFrame.new(rend(self._apoPoint))
		self._apoLabel.Text = "Ap " .. fmtAlt(self._apoR - R)
	else
		self._apoMarker.Transparency = 1
		self._apoLabel.Parent.Enabled = false
	end
end

return MapViewController
