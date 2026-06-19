--[[
	CraftRenderer
	Owner of: the rendered rocket model, the central body, and the launch pad.

	Level-of-detail so the body is never culled:
	  * Chase view: the body is drawn at most Config.RENDER.bodyFlightCap studs from
	    the camera. Beyond that it is pulled in and shrunk (angular size preserved)
	    and its continents are dropped - "quality goes down" but it stays visible.
	  * Map view: the whole scene is compressed by info.mapScale around the body so
	    the orbit always fits inside render range; the rocket/pad are parked.
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

function CraftRenderer:Init()
	self._continents = {}
	self._landShown = true
end

function CraftRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._vehicle = Registry:Get("VehicleController")
	local Flight = Registry:Get("FlightController")

	self:_cleanupWorld()
	self:_setupLighting()
	self:_buildBody()
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
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
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
	Lighting.ExposureCompensation = 0
	Lighting.GlobalShadows = false
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.FogEnd = 1e9
end

function CraftRenderer:_buildBody()
	local body = Config.BODY
	local model = Instance.new("Model")
	model.Name = "Body_" .. body.name

	local ocean = makePart(model, "Ocean", {
		Size = Vector3.new(1, 1, 1),
		Color = body.oceanColor,
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, 0, 0),
	})
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(body.radius * 2, body.radius * 2, body.radius * 2)
	mesh.Parent = ocean
	model.PrimaryPart = ocean
	self._ocean = ocean
	self._oceanMesh = mesh

	local rng = Random.new(body.continentSeed)
	local slabThickness = body.radius * 0.05
	local function slab(dir, size, color, material)
		dir = dir.Unit
		local center = dir * (body.radius + slabThickness * 0.35)
		local part = makePart(model, "Land", {
			Size = Vector3.new(size, size, slabThickness),
			Color = color,
			Material = material,
			CFrame = CFrame.lookAt(center, center + dir),
		})
		table.insert(self._continents, part)
	end
	for _ = 1, body.continents do
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		if dir.Magnitude < 1e-3 then
			dir = Vector3.yAxis
		end
		local tint = rng:NextInteger(-25, 25)
		local c = body.landColor
		slab(dir, rng:NextNumber(body.radius * 0.28, body.radius * 0.45), Color3.fromRGB(
			math.clamp(c.R * 255 + tint, 0, 255),
			math.clamp(c.G * 255 + tint, 0, 255),
			math.clamp(c.B * 255 + tint * 0.5, 0, 255)
		), Enum.Material.Grass)
	end
	slab(Vector3.yAxis, body.radius * 0.5, body.iceColor, Enum.Material.Glacier)
	slab(-Vector3.yAxis, body.radius * 0.5, body.iceColor, Enum.Material.Glacier)

	model.Parent = Workspace
	self._bodyModel = model
end

function CraftRenderer:_buildPad()
	self._pad = makePart(Workspace, "LaunchPad", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 44, 44),
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
	local root = makePart(model, "Root", {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
		CFrame = CFrame.new(0, 0, 0),
	})
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
			makePart(model, "Window", {
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.6, 1.6, 1.6),
				Color = Color3.fromRGB(120, 200, 255),
				Material = Enum.Material.Neon,
				CFrame = CFrame.new(0, center, -def.radius * 0.9),
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
	light.Range = 36
	light.Brightness = 5
	light.Enabled = false
	light.Parent = flame

	model.Parent = Workspace
	self._craft = model
	self._flame = flame
	self._flameLight = light
end

function CraftRenderer:_setLand(shown)
	if shown == self._landShown then
		return
	end
	self._landShown = shown
	for _, part in ipairs(self._continents) do
		part.Transparency = shown and 0 or 1
	end
end

function CraftRenderer:_render(state, info)
	local origin = self._origin
	local R = Config.BODY.radius
	local mapMode = info and info.mapMode
	local focusRender = origin:ToRender(Orbit.vec(0, 0, 0))

	if mapMode then
		-- Whole scene compressed around the body: body at focus, scaled down but
		-- never below a visible size.
		local s = info.mapScale or 1
		local renderedR = math.max(R * s, Config.RENDER.mapViewRadius * Config.RENDER.bodyMapMinFrac)
		self._bodyModel:PivotTo(CFrame.new(focusRender))
		self._oceanMesh.Scale = Vector3.new(renderedR * 2, renderedR * 2, renderedR * 2)
		self:_setLand(false)
		self._pad:PivotTo(CFrame.new(PARK))
		self._craft:PivotTo(CFrame.new(PARK))
		return
	end

	-- Chase view: the body is large enough to render from far, so draw it at its
	-- TRUE position and full size. It shrinks realistically with distance (down to
	-- a dot relative to the craft) instead of being culled.
	self._bodyModel:PivotTo(CFrame.new(focusRender))
	self._oceanMesh.Scale = Vector3.new(R * 2, R * 2, R * 2)
	self:_setLand(true)

	local craftRender = origin:ToRender(state.position)
	self._pad:PivotTo(CFrame.new(origin:ToRender(self._padSim)))

	-- Rocket.
	local pd = info and info.pointDir or Orbit.vec(0, 1, 0)
	self._craft:PivotTo(pointCFrame(craftRender, Vector3.new(pd.x, pd.y, pd.z)))
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
