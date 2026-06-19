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
end

function MapViewController:_setVisible(v)
	self._visible = v
	for _, seg in ipairs(self._segments) do
		seg.Transparency = v and 0 or 1
	end
	self._apoMarker.Transparency = v and 0 or 1
	self._periMarker.Transparency = v and 0 or 1
	self._craftMarker.Transparency = v and 0 or 1
end

function MapViewController:_recompute(state)
	self._simPath = Orbit.sampleOrbitPath(state, self._mu, Config.ORBITLINE.segments)

	-- Exact orbital geometry from state (eccentricity vector points to periapsis).
	local mu = self._mu
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

	self._frame += 1
	if (info and info.powered) or self._frame % 15 == 0 then
		self._needRecompute = true
	end
	if self._needRecompute or not self._simPath then
		self:_recompute(state)
		self._needRecompute = false
	end

	local focus = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local s = info.mapScale or 1
	local R = self._bodyRadius
	local function projVec(v)
		return focus + v * s
	end
	local function projSim(sp)
		return focus + Vector3.new(sp.x, sp.y, sp.z) * s
	end
	local thickness = self._bodyRadius * 0.03
	local mk = self._bodyRadius * 0.08

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
