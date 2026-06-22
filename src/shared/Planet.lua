--[[
	Planet
	ReplicatedStorage.Shared.Planet

	The single, deterministic definition of the body's surface. The planet is a sphere
	of radius Config.BODY.radius wrapped in a Perlin BIOME + heightfield: for any
	direction from the body centre there is one fixed surface radius, biome and
	material. Pure function of direction (no per-frame state, no RNG), so terrain is
	identical every visit and is rendered by distance, never re-generated.

	Biomes (Config.BIOMES): a low-frequency "elevation" field shapes oceans vs land;
	on land a "temperature" field splits the temperate band into plains (widest) /
	desert / cold, with mountains where elevation is highest. Oceans render as Water
	at sea level. Shared by:
	  * TerrainController - lays terrain columns at these heights/materials, and
	  * FlightController  - lands the craft on these heights (radar altitude).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Planet = {}

local R = Config.BODY.radius
local B = Config.BIOMES
local noise = math.noise

local GRASS = Enum.Material.Grass
local SAND = Enum.Material.Sand
local ROCK = Enum.Material.Rock
local SNOW = Enum.Material.Snow
local WATER = Enum.Material.Water

-- Colours for the distant (LOD) view, keyed by biome material.
local OCEAN_COLOR = Color3.fromRGB(38, 86, 138)
local MAT_COLOR = {
	[GRASS] = Color3.fromRGB(86, 140, 74),
	[SAND] = Color3.fromRGB(208, 188, 128),
	[SNOW] = Color3.fromRGB(236, 240, 245),
	[ROCK] = Color3.fromRGB(108, 104, 98),
}

-- Layered (fractal) Perlin in [-1, 1]-ish.
local function fbm(x, y, z, octaves, freq)
	local sum, amp, f, norm = 0, 1, freq, 0
	for i = 1, octaves do
		sum += amp * noise(x * f + i * 1.7, y * f - i * 2.3, z * f + i * 0.9)
		norm += amp
		amp *= 0.5
		f *= 2
	end
	return sum / norm
end

-- Surface sample for a unit direction: returns (height, material, isOcean).
-- height is the radius of the surface the craft lands on (oceans = sea level).
function Planet.sample(ux: number, uy: number, uz: number): (number, Enum.Material, boolean)
	local x, y, z = ux * R, uy * R, uz * R
	local elev = noise(x * B.elevFreq, y * B.elevFreq, z * B.elevFreq)
	local temp = noise(x * B.tempFreq + 53.3, y * B.tempFreq + 17.1, z * B.tempFreq + 91.7)
	local detail = fbm(x, y, z, 3, B.detailFreq)

	-- Cold concentrates toward the poles -> ice caps (both poles), so latitude pulls
	-- the temperature down. effTemp drives the temperate-land split.
	local lat = math.abs(uy) -- 0 at equator, 1 at a pole
	local poleCold = math.clamp((lat - B.poleColdStart) / (1 - B.poleColdStart), 0, 1)
	local effTemp = temp - poleCold * B.poleColdStrength

	local height, material, isOcean
	if poleCold > 0.55 then
		-- Ice cap: frozen, even over what would be ocean.
		isOcean = false
		height = R + detail * B.coldAmp
		material = SNOW
	elseif elev < B.oceanLevel then
		-- Ocean: flat water at sea level (a Water crust just below R).
		height = R
		material = WATER
		isOcean = true
	else
		isOcean = false
		local land = (elev - B.oceanLevel) / (1 - B.oceanLevel) -- 0..1
		if land > B.mountainLevel then
			local m = (land - B.mountainLevel) / (1 - B.mountainLevel) -- 0..1
			local ridged = 1 - math.abs(fbm(x, y, z, 4, B.detailFreq * 1.6))
			height = R + m * B.mountainAmp + ridged * B.mountainAmp * 0.6
			material = ((height - R) > B.snowLine) and SNOW or ROCK
		elseif effTemp < B.coldLevel then
			height = R + detail * B.coldAmp
			material = SNOW
		elseif effTemp > B.hotLevel then
			height = R + detail * B.desertAmp
			material = SAND
		else
			height = R + detail * B.plainsAmp
			material = GRASS
		end
	end

	-- Flatten the launch pole to plains so you never spawn in the sea / on a peak.
	local pole = math.clamp((uy - 0.985) / 0.015, 0, 1)
	if pole > 0 then
		height = height * (1 - pole) + (R + detail * B.plainsAmp) * pole
		if pole > 0.5 then
			isOcean = false
			material = GRASS
		end
	end

	return height, material, isOcean
end

-- Surface radius (distance from centre) for a unit direction. Hot path: this is the
-- landable height (oceans return sea level).
function Planet.radiusForUnit(ux: number, uy: number, uz: number): number
	local h = Planet.sample(ux, uy, uz)
	return h
end

function Planet.radiusForDir(dir: Vector3): number
	return Planet.radiusForUnit(dir.X, dir.Y, dir.Z)
end

-- Surface radius beneath a sim position {x,y,z} (any magnitude).
function Planet.radiusForSim(pos: { x: number, y: number, z: number }): number
	local m = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	if m < 1e-9 then
		return Planet.radiusForUnit(0, 1, 0)
	end
	return Planet.radiusForUnit(pos.x / m, pos.y / m, pos.z / m)
end

-- Distant-view colour for a unit direction: returns (Color3, isOcean). Used to paint
-- the LOD planet's biome tiles so space matches where you land.
function Planet.surfaceColor(ux: number, uy: number, uz: number): (Color3, boolean)
	local _, material, isOcean = Planet.sample(ux, uy, uz)
	if isOcean then
		return OCEAN_COLOR, true
	end
	return MAT_COLOR[material] or OCEAN_COLOR, false
end

-- Cloud density (0..1-ish) for a unit direction -- drives the LOD cloud layer.
function Planet.cloudAt(ux: number, uy: number, uz: number): number
	return fbm(ux * R, uy * R, uz * R, 3, B.cloudFreq)
end

-- Sea-level radius (the smooth datum; oceans render at this height).
function Planet.seaLevel(): number
	return R
end

-- The LOD sphere radius: just below the deepest crust (ocean sits at sea level, so
-- the lowest solid is the ocean crust bottom) so the body never pokes up through it.
function Planet.lodRadius(): number
	return R - Config.TERRAIN.crustThickness - 8
end

return Planet
