--[[
	CraftRenderer
	Owner of: the rendered rocket, the launch pad, lighting, and one-time world
	cleanup. The planet itself is real Roblox Terrain (see TerrainController), fixed
	at the world origin, so it needs no per-frame rendering here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

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
	Lighting.ClockTime = 14
	Lighting.GeographicLatitude = 25
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(80, 84, 96)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 152, 160)
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.4
	Lighting.FogEnd = 1e9
end

function CraftRenderer:_buildPad()
	-- Fixed at the +Y launch pole, top flush with the terrain there (origin is
	-- fixed, so this never moves). CanCollide so the pad reads as solid ground.
	local surf = Planet.radiusForUnit(0, 1, 0)
	makePart(Workspace, "LaunchPad", {
		Size = Vector3.new(120, 8, 120),
		Color = Color3.fromRGB(90, 92, 100),
		Material = Enum.Material.Metal,
		CFrame = CFrame.new(0, surf - 4, 0),
	})
end

function CraftRenderer:_buildLegs(model, bottomRadius)
	local L = require(Shared:WaitForChild("Config")).LEGS
	local footY = -L.standHeight
	local footR = bottomRadius * L.spread
	for i = 1, L.count do
		local ang = (i - 1) * (2 * math.pi / L.count)
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local top = Vector3.new(0, bottomRadius * 0.35, 0)
		local foot = Vector3.new(dir.X * footR, footY, dir.Z * footR)
		local mid = (top + foot) * 0.5
		local len = (foot - top).Magnitude
		makePart(model, "Leg" .. i, {
			Shape = Enum.PartType.Block,
			Size = Vector3.new(L.thickness, len, L.thickness),
			Color = L.color,
			Material = Enum.Material.Metal,
			CFrame = CFrame.lookAt(mid, foot) * CFrame.Angles(math.rad(90), 0, 0),
		})
		makePart(model, "Foot" .. i, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(L.footRadius * 2, L.footRadius * 2, L.footRadius * 2),
			Color = L.color,
			Material = Enum.Material.Metal,
			CFrame = CFrame.new(foot),
		})
	end
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
	local bottomSet = false
	local hasLegs = false
	for _, def in ipairs(parts) do
		if def.shape == "legs" then
			hasLegs = true
		else
			if not bottomSet then
				bottomRadius = def.radius
				bottomSet = true
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
	end

	if hasLegs then
		self:_buildLegs(model, bottomRadius)
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

	-- Reentry plasma envelope: a neon shell wrapping the craft, hidden until the
	-- flight loop reports reentry heating (then it glows orange -> white-hot).
	local glowH = math.max(y, 6)
	local glow = makePart(model, "Reentry", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 3.4, glowH * 1.25, bottomRadius * 3.4),
		Color = Color3.fromRGB(255, 140, 50),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CFrame = CFrame.new(0, glowH * 0.4, 0),
	})

	model.Parent = Workspace
	self._craft = model
	self._flame = flame
	self._flameLight = light
	self._reentryGlow = glow
end

function CraftRenderer:_render(state, info)
	local craftRender = self._origin:ToRender(state.position)
	local pd = info and info.pointDir or Orbit.vec(0, 1, 0)
	local up = Vector3.new(pd.x or pd.X, pd.y or pd.Y, pd.z or pd.Z)
	self._craft:PivotTo(pointCFrame(craftRender, up))

	local throttle = (info and info.throttle) or 0
	if info and info.powered and throttle > 0 then
		self._flame.Transparency = 0.2
		self._flame.Size = Vector3.new(self._flame.Size.X, 8 + 26 * throttle, self._flame.Size.Z)
		self._flameLight.Enabled = true
	else
		self._flame.Transparency = 1
		self._flameLight.Enabled = false
	end

	local re = (info and info.reentry) or 0
	if re > 0 then
		self._reentryGlow.Transparency = 1 - 0.6 * re
		-- orange (cool) -> white-hot (hot)
		self._reentryGlow.Color = Color3.fromRGB(255, 140 + math.floor(90 * re), 50 + math.floor(150 * re))
	else
		self._reentryGlow.Transparency = 1
	end
end

return CraftRenderer
