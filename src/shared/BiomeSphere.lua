--[[
	BiomeSphere
	ReplicatedStorage.Shared.BiomeSphere

	Builds a Model of biome-coloured LAND tiles wrapping a sphere of a given radius,
	centred at the model's origin (an invisible anchor PrimaryPart). Ocean cells are
	skipped so the caller's base ocean sphere shows through. The caller PivotTo's the
	model to the planet centre. Used by PlanetRenderer (true scale) and MapViewController
	(compressed) so the planet shows continents/ice/deserts from afar, matching the
	biome you actually land on (Shared.Planet).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Planet = require(Shared:WaitForChild("Planet"))

local BiomeSphere = {}

local function decor(p)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

function BiomeSphere.buildTiles(radius: number, latBands: number, lonSegs: number): Model
	local model = Instance.new("Model")
	model.Name = "BiomeTiles"

	local anchor = decor(Instance.new("Part"))
	anchor.Name = "Anchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(0, 0, 0)
	anchor.Parent = model
	model.PrimaryPart = anchor

	local latArc = radius * (math.pi / latBands)
	for i = 0, latBands - 1 do
		local theta = (i + 0.5) / latBands * math.pi
		local st, ct = math.sin(theta), math.cos(theta)
		for j = 0, lonSegs - 1 do
			local phi = (j + 0.5) / lonSegs * 2 * math.pi
			local sp, cp = math.sin(phi), math.cos(phi)
			local dir = Vector3.new(st * cp, ct, st * sp)
			local color, isOcean = Planet.surfaceColor(dir.X, dir.Y, dir.Z)
			if not isOcean then
				local lonArc = math.max(radius * st * (2 * math.pi / lonSegs), latArc * 0.5)
				local east = Vector3.new(-sp, 0, cp)
				local tile = decor(Instance.new("Part"))
				tile.Material = Enum.Material.SmoothPlastic
				tile.Color = color
				-- flat tangent slab: X=east(lon), Y=radial(thin), Z=north(lat)
				tile.Size = Vector3.new(lonArc * 1.15, 2, latArc * 1.15)
				tile.CFrame = CFrame.fromMatrix(dir * (radius + 3), east, dir)
				tile.Parent = model
			end
		end
	end
	return model
end

return BiomeSphere
