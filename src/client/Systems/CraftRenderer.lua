--[[
	CraftRenderer
	Owner of: the physical rocket assembly, the launch pad, lighting and one-time
	world cleanup.

	The craft is a REAL rigid body: a Model of welded, collidable parts with a small
	PrimaryPart "Root" (nose = root local +Y). It carries the constraints the flight
	loop drives:
	  * GravityForce  - a VectorForce applied at the centre of mass (radial gravity),
	  * ThrustForce   - a VectorForce along the nose, applied at the centre of mass,
	FlightController sets the forces every frame, sets the orientation kinematically,
	and reads the body back; this module only builds the hardware and the flame.

	Custom gravity means Workspace.Gravity is 0; every part's mass is set from the
	design via density so thrust/gravity produce the tuned accelerations.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CraftRenderer = {}

local function physProps(density)
	return PhysicalProperties.new(density, Config.PHYSICS.partFriction, Config.PHYSICS.partElasticity, 1, 1)
end

-- A structural (collidable, massful) craft part.
local function makeBody(parent, name, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = false
	p.CanCollide = true
	p.CanQuery = false
	p.CastShadow = false
	p.CustomPhysicalProperties = physProps(Config.PHYSICS.craftDensity)
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local function addCylinder(model, name, height, radius, color, material, y)
	return makeBody(model, name, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		Color = color,
		Material = material,
		CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
	})
end

function CraftRenderer:Init() end

function CraftRenderer:Start()
	self._vehicle = Registry:Get("VehicleController")
	local Flight = Registry:Get("FlightController")

	self:_cleanupWorld()
	self:_setupLighting()
	self:_buildPad()
	self:_rebuildCraft()

	self._vehicle.Changed:Connect(function()
		self:_rebuildCraft()
	end)
	Flight:GetUpdatedSignal():Connect(function(_, info)
		self:_renderFlame(info)
	end)
end

function CraftRenderer:GetCraft()
	return self._craft
end

function CraftRenderer:_cleanupWorld()
	Workspace.Gravity = 0 -- gravity is applied per-craft, radially (see FlightController)
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
	Lighting.ClockTime = 14
	Lighting.GeographicLatitude = 25
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(80, 84, 96)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 152, 160)
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.FogEnd = 1e9

	-- A black starfield sky (no atmosphere): the body is in space. rbxassetid://0
	-- gives black skybox faces; stars + the sun are still drawn.
	for _, inst in ipairs(Lighting:GetChildren()) do
		if inst:IsA("Sky") then
			inst:Destroy()
		end
	end
	local sky = Instance.new("Sky")
	sky.StarCount = 7000
	sky.CelestialBodiesShown = true
	sky.SkyboxBk = "rbxassetid://0"
	sky.SkyboxDn = "rbxassetid://0"
	sky.SkyboxFt = "rbxassetid://0"
	sky.SkyboxLf = "rbxassetid://0"
	sky.SkyboxRt = "rbxassetid://0"
	sky.SkyboxUp = "rbxassetid://0"
	sky.Parent = Lighting
end

function CraftRenderer:_buildPad()
	local Planet = require(Shared:WaitForChild("Planet"))
	local surf = Planet.radiusForUnit(0, 1, 0)
	local pad = Instance.new("Part")
	pad.Name = "LaunchPad"
	pad.Anchored = true
	pad.CanCollide = true
	pad.Size = Vector3.new(120, 8, 120)
	pad.Color = Color3.fromRGB(90, 92, 100)
	pad.Material = Enum.Material.Metal
	pad.CFrame = CFrame.new(0, surf - 4, 0)
	pad.Parent = Workspace
end

-- Build the legs as collidable feet that reach below and outside the engine bell.
function CraftRenderer:_buildLegs(model, bottomRadius)
	local L = Config.LEGS
	local footY = -L.drop
	local footR = bottomRadius * L.spread
	for i = 1, L.count do
		local ang = (i - 1) * (2 * math.pi / L.count)
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		-- Strut from near the engine top down-and-out to the foot.
		local top = Vector3.new(0, bottomRadius * 0.4, 0)
		local foot = Vector3.new(dir.X * footR, footY, dir.Z * footR)
		local mid = (top + foot) * 0.5
		local len = (foot - top).Magnitude
		makeBody(model, "Leg" .. i, {
			Shape = Enum.PartType.Block,
			Size = Vector3.new(L.thickness, len, L.thickness),
			Color = L.color,
			Material = Enum.Material.Metal,
			CanCollide = false, -- thin struts: cosmetic; the feet do the contact
			CFrame = CFrame.lookAt(mid, foot) * CFrame.Angles(math.rad(90), 0, 0),
		})
		makeBody(model, "Foot" .. i, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(L.footRadius * 2, L.footRadius * 2, L.footRadius * 2),
			Color = L.color,
			Material = Enum.Material.Metal,
			CFrame = CFrame.new(foot),
		})
	end
end

function CraftRenderer:_rebuildCraft()
	if self._craft and self._craft.model then
		self._craft.model:Destroy()
	end
	local parts = self._vehicle:GetActiveParts()

	local model = Instance.new("Model")
	model.Name = "Craft"

	local root = makeBody(model, "Root", {
		Shape = Enum.PartType.Block,
		Size = Vector3.new(0.4, 0.4, 0.4),
		Transparency = 1,
		CanCollide = false,
		CFrame = CFrame.new(0, 0, 0),
	})
	model.PrimaryPart = root

	local y = 0
	local bottomRadius = 3
	local hasLegs = false
	for index, def in ipairs(parts) do
		if def.shape == "legs" then
			hasLegs = true
		else
			if index == 1 then
				bottomRadius = def.radius
			end
			local mat = (def.category == "engine") and Enum.Material.Metal or Enum.Material.SmoothPlastic
			local center = y + def.height / 2
			addCylinder(model, def.name, def.height, def.radius, def.color, mat, center)
			if def.shape == "pod" then
				makeBody(model, "Dome", {
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
	end

	if hasLegs then
		self:_buildLegs(model, bottomRadius)
	end

	-- Flame (cosmetic, massless, non-colliding) at the engine.
	local flame = makeBody(model, "Flame", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 1.5, 12, bottomRadius * 1.5),
		Color = Color3.fromRGB(255, 150, 45),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CanCollide = false,
		CFrame = CFrame.new(0, -6, 0),
	})
	flame.Massless = true
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 70)
	light.Range = 40
	light.Brightness = 5
	light.Enabled = false
	light.Parent = flame

	-- Weld every part rigidly to the root.
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = p
			weld.Parent = root
		end
	end

	-- Attachments + constraints the flight loop drives.
	local att = Instance.new("Attachment")
	att.Name = "ControlAttachment"
	att.Parent = root

	local gravForce = Instance.new("VectorForce")
	gravForce.Name = "GravityForce"
	gravForce.Attachment0 = att
	gravForce.RelativeTo = Enum.ActuatorRelativeTo.World
	gravForce.ApplyAtCenterOfMass = true
	gravForce.Force = Vector3.zero
	gravForce.Parent = root

	local thrustForce = Instance.new("VectorForce")
	thrustForce.Name = "ThrustForce"
	thrustForce.Attachment0 = att
	thrustForce.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	thrustForce.ApplyAtCenterOfMass = true -- thrust along nose, through CoM: no spurious torque
	thrustForce.Force = Vector3.zero
	thrustForce.Parent = root

	-- Orientation is set kinematically by FlightController (no AlignOrientation):
	-- physics handles translation, the flight loop handles rotation. This avoids the
	-- rigid-constraint-vs-collision energy pumping that was flinging the craft.

	model.Parent = Workspace

	self._craft = {
		model = model,
		root = root,
		gravForce = gravForce,
		thrustForce = thrustForce,
		flame = flame,
		flameLight = light,
		bottomRadius = bottomRadius,
	}
end

function CraftRenderer:_renderFlame(info)
	local c = self._craft
	if not c or not c.flame then
		return
	end
	local throttle = (info and info.throttle) or 0
	if info and info.powered and throttle > 0 then
		c.flame.Transparency = 0.2
		c.flame.Size = Vector3.new(c.flame.Size.X, 8 + 26 * throttle, c.flame.Size.Z)
		c.flameLight.Enabled = true
	else
		c.flame.Transparency = 1
		c.flameLight.Enabled = false
	end
end

return CraftRenderer
