--[[
	CraftRenderer
	Owner of: the rendered planet, launch pad, and rocket.

	The planet is a REAL Ball part rendered CAMERA-RELATIVE: each frame it is placed
	along the true direction to the body, at a distance scaled so its angular size
	matches reality. Because it is a normal, close part it can never be culled, yet
	it shrinks naturally to a dot as you fly away. Continents share the body's seed
	so the correct face shows as you orbit. Map view uses a small body at the
	compressed focus instead.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CraftRenderer = {}

local PARK = Vector3.new(0, Config.RENDER.parkY, 0)

local function makePart(parent, name, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local function addCylinder(model, name, height, radius, color, material, y)
	return makePart(model, name, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		Color = color,
		Material = material,
		CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
	})
end

local function pointCFrame(posVec3, upVec3)
	local up = (upVec3.Magnitude > 1e-3) and upVec3.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(posVec3, posVec3 + fwd.Unit, up)
end

function CraftRenderer:Init() end

function CraftRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._vehicle = Registry:Get("VehicleController")
	local Flight = Registry:Get("FlightController")

	self:_cleanupWorld()
	self:_setupLighting()
	self:_buildPlanetProxy()
	self:_buildMapPlanet()
	self:_buildPad()
	self:_rebuildCraft()

	self._vehicle.Changed:Connect(function()
		self:_rebuildCraft()
	end)
	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_render(state, info)
	end)
end

function CraftRenderer:_cleanupWorld()
	for _, inst in ipairs(Lighting:GetChildren()) do
		if inst:IsA("Atmosphere") or inst:IsA("Sky") then
			inst:Destroy()
		end
	end
	local bp = Workspace:FindFirstChild("Baseplate")
	if bp then
		bp:Destroy()
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("SpawnLocation") then
			inst:Destroy()
		end
	end
end

function CraftRenderer:_setupLighting()
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 20
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(70, 72, 85)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 160)
	Lighting.GlobalShadows = false
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.FogEnd = 1e9
end

-- Continent surface directions, shared between the flight proxy and (visually)
-- the real planet so the correct face shows.
function CraftRenderer:_continentDirs()
	local dirs = {}
	local rng = Random.new(Config.BODY.continentSeed)
	for _ = 1, Config.BODY.continents do
		local d = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		if d.Magnitude < 1e-3 then
			d = Vector3.yAxis
		end
		dirs[#dirs + 1] = { dir = d.Unit, size = rng:NextNumber(0.28, 0.42) }
	end
	return dirs
end

function CraftRenderer:_buildPlanetProxy()
	local body = Config.BODY
	local pr = Config.RENDER.proxyRadius
	local model = Instance.new("Model")
	model.Name = "PlanetProxy"

	local ocean = makePart(model, "Ocean", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(pr * 2, pr * 2, pr * 2),
		Color = body.oceanColor,
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, 0, 0),
	})
	model.PrimaryPart = ocean

	for _, c in ipairs(self:_continentDirs()) do
		makePart(model, "Land", {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(pr * c.size * 2, pr * c.size * 2, pr * c.size * 0.6),
			Color = body.landColor,
			Material = Enum.Material.Grass,
			CFrame = CFrame.lookAt(c.dir * pr, c.dir * pr * 2),
		})
	end
	for _, pole in ipairs({ Vector3.yAxis, -Vector3.yAxis }) do
		makePart(model, "Ice", {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(pr * 0.7, pr * 0.7, pr * 0.4),
			Color = body.iceColor,
			Material = Enum.Material.Glacier,
			CFrame = CFrame.lookAt(pole * pr, pole * pr * 2),
		})
	end

	model.Parent = Workspace
	self._planetProxy = model
end

function CraftRenderer:_buildMapPlanet()
	local r = Config.RENDER.mapPlanetRadius
	self._mapPlanet = makePart(Workspace, "MapPlanet", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(r * 2, r * 2, r * 2),
		Color = Config.BODY.landColor,
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(PARK),
	})
end

function CraftRenderer:_buildPad()
	self._pad = makePart(Workspace, "LaunchPad", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(6, 90, 90),
		Color = Color3.fromRGB(90, 92, 100),
		Material = Enum.Material.Metal,
	})
	self._padSim = Orbit.vec(Config.BODY.radius, 0, 0)
end

function CraftRenderer:_rebuildCraft()
	if self._craft then
		self._craft:Destroy()
	end
	local parts = self._vehicle:GetActiveParts()

	local model = Instance.new("Model")
	model.Name = "Craft"
	local root = makePart(model, "Root", { Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, CFrame = CFrame.new(0, 0, 0) })
	model.PrimaryPart = root

	local y = 0
	local bottomRadius = 3
	for index, def in ipairs(parts) do
		if index == 1 then
			bottomRadius = def.radius
		end
		local mat = (def.category == "engine") and Enum.Material.Metal or Enum.Material.SmoothPlastic
		local center = y + def.height / 2
		addCylinder(model, def.name, def.height, def.radius, def.color, mat, center)
		if def.shape == "pod" then
			makePart(model, "Dome", {
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(def.radius * 1.8, def.radius * 1.4, def.radius * 1.8),
				Color = def.color,
				Material = Enum.Material.SmoothPlastic,
				CFrame = CFrame.new(0, y + def.height, 0),
			})
		elseif def.shape == "engine" then
			addCylinder(model, "Nozzle", def.height * 0.5, def.radius * 0.66, Color3.fromRGB(40, 42, 48), Enum.Material.Metal, y - def.height * 0.1)
		end
		y += def.height
	end

	local flame = makePart(model, "Flame", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 1.5, 12, bottomRadius * 1.5),
		Color = Color3.fromRGB(255, 150, 45),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CFrame = CFrame.new(0, -6, 0),
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 70)
	light.Range = 40
	light.Brightness = 5
	light.Enabled = false
	light.Parent = flame

	model.Parent = Workspace
	self._craft = model
	self._flame = flame
	self._flameLight = light
end

function CraftRenderer:_render(state, info)
	local origin = self._origin
	local R = Config.BODY.radius
	local focus = origin:ToRender(Orbit.vec(0, 0, 0))
	local mapMode = info and info.mapMode

	if mapMode then
		self._planetProxy:PivotTo(CFrame.new(PARK))
		self._mapPlanet:PivotTo(CFrame.new(focus))
		self._pad:PivotTo(CFrame.new(PARK))
		self._craft:PivotTo(CFrame.new(PARK))
		return
	end

	self._mapPlanet:PivotTo(CFrame.new(PARK))

	-- Camera-relative planet proxy.
	local camPos = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position or focus
	local toBody = focus - camPos
	local mag = toBody.Magnitude
	if mag < 1e-3 then
		toBody = Vector3.new(0, -1, 0)
		mag = 1
	end
	local D = math.max(mag, R)
	local dir = toBody / mag
	local proxyDist = math.clamp(
		Config.RENDER.proxyRadius * D / R,
		Config.RENDER.proxyDistMin,
		Config.RENDER.proxyDistMax
	)
	self._planetProxy:PivotTo(CFrame.new(camPos + dir * proxyDist))

	-- Pad + rocket at true positions.
	local craftRender = origin:ToRender(state.position)
	self._pad:PivotTo(CFrame.new(origin:ToRender(self._padSim)))

	local pd = info and info.pointDir or Orbit.vec(0, 1, 0)
	self._craft:PivotTo(pointCFrame(craftRender, Vector3.new(pd.x or pd.X, pd.y or pd.Y, pd.z or pd.Z)))

	local throttle = (info and info.throttle) or 0
	if info and info.powered and throttle > 0 then
		self._flame.Transparency = 0.2
		self._flame.Size = Vector3.new(self._flame.Size.X, 8 + 26 * throttle, self._flame.Size.Z)
		self._flameLight.Enabled = true
	else
		self._flame.Transparency = 1
		self._flameLight.Enabled = false
	end
end

return CraftRenderer
