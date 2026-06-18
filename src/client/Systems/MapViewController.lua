--[[
	MapViewController
	Owner of: the orbit trajectory line, the apo/peri markers, and the craft
	marker (so you can see where the rocket is when zoomed out).

	The orbit shape is fixed while coasting, so the (expensive) Orbit.sampleOrbitPath
	is only recomputed when the trajectory actually changes (a burn), when the map
	is shown, and occasionally as a safety. Every frame it just re-projects the
	cached sim points through the floating origin - cheap - so time warp stays
	smooth.

	Visible only in map view (toggle M).
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

function MapViewController:Init()
	self._segments = {}
	self._visible = false
	self._needRecompute = true
	self._frame = 0
	self._simPath = nil
	self._maxI = 1
	self._minI = 1
	self._thickness = Config.ORBITLINE.thicknessMin
	self._closed = true
end

function MapViewController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")
	local Flight = Registry:Get("FlightController")
	self._mu = Flight:GetMu()

	self:_buildPool()
	self:_setVisible(self._input:GetMapMode())

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
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

	for i = 1, cfg.segments do
		self._segments[i] = newPart(cfg.color)
	end
	self._apoMarker = newPart(cfg.apoColor, Enum.PartType.Ball)
	self._periMarker = newPart(cfg.periColor, Enum.PartType.Ball)
	self._craftMarker = newPart(cfg.craftColor, Enum.PartType.Ball)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CraftLabel"
	billboard.Size = UDim2.fromOffset(80, 20)
	billboard.AlwaysOnTop = true
	billboard.Adornee = self._craftMarker
	billboard.Parent = self._craftMarker
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextColor3 = cfg.craftColor
	label.Text = "CRAFT"
	label.Parent = billboard
	self._craftLabel = billboard
end

function MapViewController:_setVisible(visible)
	self._visible = visible
	for _, seg in ipairs(self._segments) do
		seg.Transparency = visible and 0 or 1
	end
	self._apoMarker.Transparency = visible and 0 or 1
	self._periMarker.Transparency = visible and 0 or 1
	self._craftMarker.Transparency = visible and 0 or 1
	self._craftLabel.Enabled = visible
end

function MapViewController:_recompute(state)
	local cfg = Config.ORBITLINE
	local pts = Orbit.sampleOrbitPath(state, self._mu, cfg.segments)
	local readout = Orbit.getReadout(state, self._mu)

	local apoR = (readout.apoapsis < math.huge) and readout.apoapsis or mag(state.position)
	self._thickness = math.clamp(apoR * cfg.thicknessScale, cfg.thicknessMin, cfg.thicknessMax)
	self._closed = readout.apoapsis < math.huge

	local maxD, minD, maxI, minI = -1, math.huge, 1, 1
	for i = 1, #pts do
		local d = mag(pts[i])
		if d > maxD then
			maxD, maxI = d, i
		end
		if d < minD then
			minD, minI = d, i
		end
	end
	self._simPath = pts
	self._maxI = maxI
	self._minI = minI
end

function MapViewController:_update(state, info)
	if not self._input:GetMapMode() then
		if self._visible then
			self:_setVisible(false)
		end
		return
	elseif not self._visible then
		self:_setVisible(true)
		self._needRecompute = true
	end

	self._frame += 1
	if (info and info.powered) or self._frame % 30 == 0 then
		self._needRecompute = true
	end
	if self._needRecompute or not self._simPath then
		self:_recompute(state)
		self._needRecompute = false
	end

	local origin = self._origin
	local pts = self._simPath
	local n = #pts
	local render = table.create(n)
	for i = 1, n do
		render[i] = origin:ToRender(pts[i])
	end

	local thickness = self._thickness
	local segs = self._segments
	for i = 1, #segs do
		local a = render[i]
		local b = render[i + 1]
		local seg = segs[i]
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
			end
		end
	end

	local mk = thickness * 3
	self._craftMarker.Transparency = 0
	self._craftMarker.Size = Vector3.new(mk, mk, mk)
	self._craftMarker.CFrame = CFrame.new(origin:ToRender(state.position))

	if self._closed then
		self._apoMarker.Transparency = 0
		self._periMarker.Transparency = 0
		self._apoMarker.Size = Vector3.new(mk, mk, mk)
		self._periMarker.Size = Vector3.new(mk, mk, mk)
		self._apoMarker.CFrame = CFrame.new(render[self._maxI])
		self._periMarker.CFrame = CFrame.new(render[self._minI])
	else
		self._apoMarker.Transparency = 1
		self._periMarker.Transparency = 1
	end
end

return MapViewController
