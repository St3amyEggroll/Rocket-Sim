--[[
	CraftRenderer
	Owner of: the rendered craft model and the central body model.

	Listens to FlightController.Updated and re-pivots both the craft and the body
	through the floating origin every frame. Nothing here stores sim state - it
	only converts sim positions to render-space Vector3s via the origin.

	(Phase 1 also does the bit of world ambiance here. A dedicated WorldRenderer
	can take this over in a later phase.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CraftRenderer = {}

function CraftRenderer:Init()
	self._craft = nil
	self._body = nil
end

function CraftRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")

	self:_setupAmbiance()
	self:_buildBody()
	self:_buildCraft()

	-- Initial placement before the loop fires.
	self:_render(Flight:GetState())

	Flight:GetUpdatedSignal():Connect(function(state)
		self:_render(state)
	end)
end

function CraftRenderer:_setupAmbiance()
	-- A starfield-at-night look with flat ambient lighting so the body is visible
	-- even with the sun below the horizon. Cosmetic only; client-side.
	Lighting.ClockTime = 0
	Lighting.Brightness = 1
	Lighting.Ambient = Color3.fromRGB(95, 100, 115)
	Lighting.OutdoorAmbient = Color3.fromRGB(95, 100, 115)
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	Lighting.GlobalShadows = false
	Lighting.FogEnd = 1e9
end

function CraftRenderer:_buildBody()
	local body = Config.BODY

	-- A Part is capped at 2048 studs, so the body is a unit Part driven by a
	-- SpecialMesh sphere scaled to the true diameter.
	local part = Instance.new("Part")
	part.Name = "Body_" .. body.name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.new(1, 1, 1)
	part.Color = body.color
	part.Material = body.material

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(body.radius * 2, body.radius * 2, body.radius * 2)
	mesh.Parent = part

	part.Parent = Workspace
	self._body = part
end

function CraftRenderer:_buildCraft()
	local c = Config.CRAFT

	local part = Instance.new("Part")
	part.Name = "TestCraft"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.new(c.radius * 2, c.radius * 2, c.radius * 2)
	part.Color = c.color
	part.Material = Enum.Material.Metal

	-- A small light so the craft reads against the dark sky.
	local light = Instance.new("PointLight")
	light.Range = c.radius * 8
	light.Brightness = 2
	light.Parent = part

	part.Parent = Workspace
	self._craft = part
end

function CraftRenderer:_render(state)
	local origin = self._origin

	if self._body then
		-- The body lives at the sim origin (0,0,0).
		local bodyRender = origin:ToRender(Orbit.vec(0, 0, 0))
		self._body:PivotTo(CFrame.new(bodyRender))
	end

	if self._craft then
		local craftRender = origin:ToRender(state.position)
		local v = state.velocity
		local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
		if speed > 1e-3 then
			-- Point the nose along velocity for a sense of motion.
			local look = craftRender + Vector3.new(v.x, v.y, v.z).Unit
			self._craft:PivotTo(CFrame.lookAt(craftRender, look))
		else
			self._craft:PivotTo(CFrame.new(craftRender))
		end
	end
end

return CraftRenderer
