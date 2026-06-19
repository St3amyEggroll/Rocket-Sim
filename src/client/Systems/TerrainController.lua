--[[
	TerrainController
	Builds the planet: a real grass Ball part (so it renders at any distance and
	never culls), plus a real Roblox-Terrain grass patch at the +Y launch pole for
	walkable ground detail at the launch site. No water/rock blobs - clean grass.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))

local TerrainController = {}

function TerrainController:Init() end

function TerrainController:Start()
	self:_buildBody()
	task.spawn(function()
		self:_buildLaunchTerrain()
	end)
end

function TerrainController:_buildBody()
	local body = Config.BODY
	local R = body.radius
	local planet = Instance.new("Part")
	planet.Name = "Planet"
	planet.Shape = Enum.PartType.Ball
	planet.Size = Vector3.new(R * 2, R * 2, R * 2) -- <=2048; a real, never-culled part
	planet.Anchored = true
	planet.CanCollide = true
	planet.Color = body.grassColor
	planet.Material = Enum.Material.Grass
	planet.CFrame = CFrame.new(0, 0, 0)
	planet.Parent = Workspace
	self._planet = planet
end

function TerrainController:_buildLaunchTerrain()
	local body = Config.BODY
	local R = body.radius
	local terrain = Workspace.Terrain
	terrain:Clear()
	pcall(function()
		terrain:SetMaterialColor(Enum.Material.Grass, body.grassColor)
	end)

	-- Flat grass field at the +Y pole (top at the surface, R). Light voxel count.
	terrain:FillBlock(CFrame.new(0, R - 30, 0), Vector3.new(800, 60, 800), Enum.Material.Grass)

	-- A few subtle low hills for relief (not big spheres).
	local rng = Random.new(body.seed)
	for _ = 1, 8 do
		local x = rng:NextNumber(-320, 320)
		local z = rng:NextNumber(-320, 320)
		terrain:FillBall(Vector3.new(x, R - 8, z), rng:NextNumber(28, 55), Enum.Material.Grass)
	end
end

return TerrainController
