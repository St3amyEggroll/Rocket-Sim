--[[
	MapViewController
	Owner of: the orbit trajectory line and the apoapsis / periapsis markers.

	Draws the current orbit with Orbit.sampleOrbitPath as a chain of thin neon
	segments in 3D world space, refreshed every frame through the floating origin
	(so the line shifts correctly on rebases and morphs live while you burn).

	Visible only in map view (toggle M). While coasting the orbit is fixed, so
	the line is stable; while thrusting it updates as the trajectory changes.
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
end

function MapViewController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")
	local Flight = Registry:Get("FlightController")
	self._mu = Flight:GetMu()

	self:_buildPool()
	self:_setVisible(self._input:GetMapMode())

	Flight:GetUpdatedSignal():Connect(function(state)
		self:_update(state)
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
end

function MapViewController:_setVisible(visible)
	self._visible = visible
	for _, seg in ipairs(self._segments) do
		seg.Transparency = visible and 0 or 1
	end
	self._apoMarker.Transparency = visible and 0 or 1
	self._periMarker.Transparency = visible and 0 or 1
end

function MapViewController:_update(state)
	local mapMode = self._input:GetMapMode()
	if not mapMode then
		if self._visible then
			self:_setVisible(false)
		end
		return
	elseif not self._visible then
		self:_setVisible(true)
	end

	local cfg = Config.ORBITLINE
	local origin = self._origin
	local pts = Orbit.sampleOrbitPath(state, self._mu, cfg.segments)

	local readout = Orbit.getReadout(state, self._mu)
	local apoR = (readout.apoapsis < math.huge) and readout.apoapsis or mag(state.position)
	local thickness = math.clamp(apoR * cfg.thicknessScale, cfg.thicknessMin, cfg.thicknessMax)

	-- Convert to render space; track the farthest / nearest points for markers.
	local n = #pts
	local render = table.create(n)
	local maxD, minD, maxI, minI = -1, math.huge, 1, 1
	for i = 1, n do
		local sp = pts[i]
		render[i] = origin:ToRender(sp)
		local d = mag(sp)
		if d > maxD then
			maxD, maxI = d, i
		end
		if d < minD then
			minD, minI = d, i
		end
	end

	-- One segment per gap between consecutive sample points.
	local segs = self._segments
	for i = 1, #segs do
		local a = render[i]
		local b = render[i + 1]
		local seg = segs[i]
		if not b then
			seg.Transparency = 1
		else
			local delta = b - a
			local len = delta.Magnitude
			if len < 1e-3 then
				seg.Transparency = 1
			else
				seg.Transparency = 0
				seg.Size = Vector3.new(thickness, thickness, len)
				seg.CFrame = CFrame.lookAt((a + b) * 0.5, b)
			end
		end
	end

	-- Apo/peri markers (only meaningful for a closed orbit).
	if readout.apoapsis < math.huge then
		local mk = thickness * 3
		self._apoMarker.Transparency = 0
		self._periMarker.Transparency = 0
		self._apoMarker.Size = Vector3.new(mk, mk, mk)
		self._periMarker.Size = Vector3.new(mk, mk, mk)
		self._apoMarker.CFrame = CFrame.new(render[maxI])
		self._periMarker.CFrame = CFrame.new(render[minI])
	else
		self._apoMarker.Transparency = 1
		self._periMarker.Transparency = 1
	end
end

return MapViewController
