--[[
	TerrainController
	Builds the planet as a single Roblox-Terrain grass sphere at the world origin
	(the floating origin is fixed at 0 for this small world, so sim == world).
	Generated once at start - no streaming, nothing to unload. Grass everywhere,
	with oceans, rocky mountains, and an ice cap; the +Y pole is kept clear as the
	launch site.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))

local TerrainController = {}

function TerrainController:Init() end

function TerrainController:Start()
	task.spawn(function()
		self:_generate()
	end)
end

function TerrainController:_generate()
	local body = Config.BODY
	local R = body.radius
	local terrain = Workspace.Terrain
	terrain:Clear()

	pcall(function()
		terrain:SetMaterialColor(Enum.Material.Grass, body.grassColor)
		terrain:SetMaterialColor(Enum.Material.Rock, body.rockColor)
		terrain:SetMaterialColor(Enum.Material.Sand, body.sandColor)
		terrain:SetMaterialColor(Enum.Material.Water, body.waterColor)
	end)

	-- The planet itself (one big grass ball at the origin).
	terrain:FillBall(Vector3.zero, R, Enum.Material.Grass)

	local rng = Random.new(body.seed)
	local function randDir()
		local d = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		if d.Magnitude < 1e-3 then
			d = Vector3.yAxis
		end
		return d.Unit
	end

	-- Oceans (carve water into the crust), away from the +Y launch pole.
	for _ = 1, 8 do
		local d = randDir()
		if d.Y < 0.55 then
			terrain:FillBall(d * (R - 25), rng:NextNumber(110, 190), Enum.Material.Water)
		end
	end

	-- Mountains (rock bumps above the surface).
	for _ = 1, 12 do
		local d = randDir()
		if d.Y < 0.7 then
			terrain:FillBall(d * (R + 8), rng:NextNumber(35, 80), Enum.Material.Rock)
		end
	end

	-- Ice cap at the south pole.
	terrain:FillBall(Vector3.new(0, -1, 0) * R, R * 0.38, Enum.Material.Glacier)

	-- A small flat grass clearing at the launch pole (overwrite anything stray).
	terrain:FillBall(Vector3.new(0, 1, 0) * (R - 6), 120, Enum.Material.Grass)
end

return TerrainController
