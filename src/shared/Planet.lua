--[[
	Planet
	ReplicatedStorage.Shared.Planet

	The single, deterministic definition of the body's surface. The planet is a
	Perlin-noise heightfield wrapped over a sphere of radius Config.BODY.radius:
	for any direction from the body centre there is one fixed surface radius. This
	is the source of truth shared by:
	  * TerrainController - lays real terrain at these heights, and
	  * FlightController  - lands the craft on these heights (radar altitude).

	Because it is a pure function of direction (no per-frame state, no RNG), the
	terrain is the same every time you visit a spot - it is rendered by distance,
	never re-generated.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Planet = {}

local R = Config.BODY.radius
local AMP = Config.TERRAIN.reliefAmp
local FREQ = Config.TERRAIN.reliefFreq

local noise = math.noise

-- Two octaves of Perlin noise over the surface point, normalised to ~[-1, 1].
local function relief(ux: number, uy: number, uz: number): number
	local x, y, z = ux * R, uy * R, uz * R
	local n1 = noise(x * FREQ, y * FREQ, z * FREQ)
	local n2 = noise(x * FREQ * 2.7 + 13.1, y * FREQ * 2.7 + 41.7, z * FREQ * 2.7 + 7.3)
	return (n1 + n2 * 0.35) / 1.35
end

-- Surface radius (distance from body centre) for a unit direction given as
-- three components. Hot path for terrain generation.
function Planet.radiusForUnit(ux: number, uy: number, uz: number): number
	return R + relief(ux, uy, uz) * AMP
end

-- Surface radius for a render-space unit direction (Vector3).
function Planet.radiusForDir(dir: Vector3): number
	return Planet.radiusForUnit(dir.X, dir.Y, dir.Z)
end

-- Surface radius beneath a sim position {x,y,z} (any magnitude).
function Planet.radiusForSim(pos: { x: number, y: number, z: number }): number
	local m = math.sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
	if m < 1e-9 then
		return R + relief(0, 1, 0) * AMP
	end
	return Planet.radiusForUnit(pos.x / m, pos.y / m, pos.z / m)
end

-- Sea-level radius (the smooth datum the Ball LOD and orbit readout use).
function Planet.seaLevel(): number
	return R
end

-- The Ball LOD radius: just below the lowest possible terrain so the smooth
-- sphere never pokes up through a terrain valley while the crust is loaded.
function Planet.lodRadius(): number
	return R - AMP - 6
end

return Planet
