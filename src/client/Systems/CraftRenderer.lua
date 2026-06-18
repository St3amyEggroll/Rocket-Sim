--[[
	CraftRenderer
	Owner of: the rendered rocket model and the central body model.

	Listens to FlightController.Updated and re-pivots both through the floating
	origin every frame. The rocket flies nose-forward (prograde) with its engine
	flame at the back; the body is a lit planet with oceans, continents and ice.
	Nothing here stores sim state - it only converts sim positions to render-space
	Vector3s via the origin.

	(Phase 1/2 also sets up the lighting here. A dedicated WorldRenderer can take
	this over later.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CraftRenderer = {}

-- Pick a "forward" (prograde) that is not parallel to "up" (radial), so the
-- orientation CFrame is always well defined.
local function safeForward(up, forward)
	if forward.Magnitude < 1e-3 or math.abs(forward.Unit:Dot(up)) > 0.99 then
		local f = up:Cross(Vector3.xAxis)
		if f.Magnitude < 1e-3 then
			f = up:Cross(Vector3.zAxis)
		end
		return f.Unit
	end
	return forward.Unit
end

function CraftRenderer:Init()
	self._craft = nil
	self._body = nil
	self._flame = nil
	self._flameLight = nil
end

function CraftRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")

	self:_cleanupWorld()
	self:_setupLighting()
	self:_buildBody()
	self:_buildCraft()

	self:_render(Flight:GetState(), { throttle = 0, powered = false })

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_render(state, info)
	end)
end

function CraftRenderer:_cleanupWorld()
	-- The default Baseplate template ships an Atmosphere (that is the "fog") plus
	-- a baseplate and spawn that sit right where our craft renders. Remove them
	-- so the space scene is clean.
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
	-- Daytime sun so the planet and rocket are clearly lit and shaded (reads as
	-- 3D). Cosmetic, client-side.
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

function CraftRenderer:_buildBody()
	local body = Config.BODY
	local model = Instance.new("Model")
	model.Name = "Body_" .. body.name

	-- Ocean sphere (a unit Part stretched by a SpecialMesh, since Parts cap at
	-- 2048 studs).
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

	-- Continent / ice slabs sitting tangent to the surface (a thin face pokes out
	-- so they read as land from orbit).
	local rng = Random.new(body.continentSeed)
	local slabThickness = body.radius * 0.05
	local function slab(dir, size, color, material)
		dir = dir.Unit
		makePart(model, "Land", {
			Size = Vector3.new(size, size, slabThickness),
			Color = color,
			Material = material,
			-- thin Z axis points outward along the surface normal
			CFrame = CFrame.lookAt(dir * body.radius, dir * (body.radius * 2)),
		})
	end

	for _ = 1, body.continents do
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		if dir.Magnitude < 1e-3 then
			dir = Vector3.yAxis
		end
		local tint = rng:NextInteger(-25, 25)
		local c = body.landColor
		local color = Color3.fromRGB(
			math.clamp(c.R * 255 + tint, 0, 255),
			math.clamp(c.G * 255 + tint, 0, 255),
			math.clamp(c.B * 255 + tint * 0.5, 0, 255)
		)
		slab(dir, rng:NextNumber(body.radius * 0.28, body.radius * 0.45), color, Enum.Material.Grass)
	end
	-- Ice caps.
	slab(Vector3.yAxis, body.radius * 0.5, body.iceColor, Enum.Material.Glacier)
	slab(-Vector3.yAxis, body.radius * 0.5, body.iceColor, Enum.Material.Glacier)

	model.Parent = Workspace
	self._body = model
end

function CraftRenderer:_buildCraft()
	-- Rocket authored along -Z (nose forward) with +Y as "up" (the side the
	-- avatar rides). PivotTo orients it each frame.
	local model = Instance.new("Model")
	model.Name = "Craft"

	local body = makePart(model, "Body", {
		Size = Vector3.new(8, 8, 22),
		Color = Color3.fromRGB(232, 236, 244),
		Material = Enum.Material.Metal,
		CFrame = CFrame.new(0, 0, 0),
	})
	model.PrimaryPart = body

	makePart(model, "Nose", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(8, 8, 9),
		Color = Color3.fromRGB(214, 78, 78),
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, 0, -13),
	})
	makePart(model, "Stripe", {
		Size = Vector3.new(8.2, 8.2, 3),
		Color = Color3.fromRGB(196, 60, 60),
		Material = Enum.Material.SmoothPlastic,
		CFrame = CFrame.new(0, 0, -4),
	})
	makePart(model, "Window", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3.5, 3.5, 3.5),
		Color = Color3.fromRGB(120, 200, 255),
		Material = Enum.Material.Neon,
		CFrame = CFrame.new(0, 3.4, -7),
	})
	makePart(model, "Engine", {
		Size = Vector3.new(6, 6, 3),
		Color = Color3.fromRGB(60, 62, 72),
		Material = Enum.Material.Metal,
		CFrame = CFrame.new(0, 0, 12.5),
	})

	-- Four fins around the tail.
	for i = 0, 3 do
		local a = math.rad(i * 90)
		makePart(model, "Fin" .. i, {
			Size = Vector3.new(1.4, 5, 6),
			Color = Color3.fromRGB(196, 60, 60),
			Material = Enum.Material.SmoothPlastic,
			CFrame = CFrame.fromAxisAngle(Vector3.zAxis, a) * CFrame.new(0, 5, 9),
		})
	end

	-- Exhaust flame (hidden unless thrusting).
	local flame = makePart(model, "Flame", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(6, 6, 10),
		Color = Color3.fromRGB(255, 150, 45),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CFrame = CFrame.new(0, 0, 17),
	})
	local flameLight = Instance.new("PointLight")
	flameLight.Color = Color3.fromRGB(255, 160, 70)
	flameLight.Range = 40
	flameLight.Brightness = 5
	flameLight.Enabled = false
	flameLight.Parent = flame

	model.Parent = Workspace
	self._craft = model
	self._flame = flame
	self._flameLight = flameLight
end

function CraftRenderer:_render(state, info)
	local origin = self._origin

	-- Body sits at the sim origin.
	self._body:PivotTo(CFrame.new(origin:ToRender(Orbit.vec(0, 0, 0))))

	-- Rocket: nose along prograde, "up" radial-out.
	local p = state.position
	local up = Vector3.new(p.x, p.y, p.z)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	local v = state.velocity
	local forward = safeForward(up, Vector3.new(v.x, v.y, v.z))

	local craftRender = origin:ToRender(state.position)
	-- LookVector(-Z) = forward (prograde); UpVector(+Y) = up (radial-out).
	self._craft:PivotTo(CFrame.lookAt(craftRender, craftRender + forward, up))

	-- Flame.
	local throttle = (info and info.throttle) or 0
	if info and info.powered and throttle > 0 then
		self._flame.Transparency = 0.2
		self._flame.Size = Vector3.new(6, 6, 8 + 22 * throttle)
		self._flameLight.Enabled = true
	else
		self._flame.Transparency = 1
		self._flameLight.Enabled = false
	end
end

return CraftRenderer
