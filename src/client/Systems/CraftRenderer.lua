--[[
	CraftRenderer
	Owner of: the rendered rocket model, the central body, and the launch pad.

	The rocket is built from VehicleController's ACTIVE parts (rebuilt when parts
	change or a stage drops) and oriented each frame so it points along the
	flight's pointDir, with its exhaust flame at the tail. The body is a lit planet
	with oceans/continents/ice. Everything is placed through the floating origin.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CraftRenderer = {}

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

-- A vertical cylinder (length along the model's +Y), centred at local y.
local function addCylinder(model, name, height, radius, color, material, y)
	return makePart(model, name, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		Color = color,
		Material = material,
		CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
	})
end

function CraftRenderer:Init()
	self._craft = nil
	self._body = nil
	self._pad = nil
	self._flame = nil
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

	local rng = Random.new(body.continentSeed)
	local slabThickness = body.radius * 0.05
	local function slab(dir, size, color, material)
		dir = dir.Unit
		-- Sit a little proud of the surface so flat slabs don't z-fight the sphere.
		local center = dir * (body.radius + slabThickness * 0.35)
		makePart(model, "Land", {
			Size = Vector3.new(size, size, slabThickness),
			Color = color,
			Material = material,
			CFrame = CFrame.lookAt(center, center + dir),
		})
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
	self._body = model
end

function CraftRenderer:_buildPad()
	-- Launch pad sits on the surface at (radius,0,0); axis points along +X (the
	-- surface normal there). Fixed in sim space; only its render position moves.
	local pad = makePart(Workspace, "LaunchPad", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 44, 44),
		Color = Color3.fromRGB(90, 92, 100),
		Material = Enum.Material.Metal,
	})
	self._pad = pad
	self._padSim = Orbit.vec(Config.BODY.radius, 0, 0)
end

function CraftRenderer:_rebuildCraft()
	if self._craft then
		self._craft:Destroy()
	end
	local parts = self._vehicle:GetActiveParts() -- bottom -> top

	local model = Instance.new("Model")
	model.Name = "Craft"
	-- Invisible, unrotated root at the base so PivotTo orientation stays clean.
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

	-- Exhaust flame below the base (hidden unless thrusting).
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

local function pointCFrame(posVec3, upVec3)
	local up = (upVec3.Magnitude > 1e-3) and upVec3.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	-- UpVector = up (rocket nose / +Y); LookVector = fwd (cosmetic for symmetry).
	return CFrame.lookAt(posVec3, posVec3 + fwd.Unit, up)
end

function CraftRenderer:_render(state, info)
	local origin = self._origin

	self._body:PivotTo(CFrame.new(origin:ToRender(Orbit.vec(0, 0, 0))))

	if self._pad then
		-- Pad axis (+X local) aligned to the launch-site normal (+X).
		self._pad:PivotTo(CFrame.new(origin:ToRender(self._padSim)))
	end

	if self._craft then
		local pd = info and info.pointDir or Orbit.vec(0, 1, 0)
		local up = Vector3.new(pd.x, pd.y, pd.z)
		self._craft:PivotTo(pointCFrame(origin:ToRender(state.position), up))

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
end

return CraftRenderer
