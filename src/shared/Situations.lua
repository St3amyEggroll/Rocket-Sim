--[[
	Situations
	ReplicatedStorage.Shared.Situations

	Turns the live flight telemetry into a { body, biome, situation } context -- the basis of
	biome/situation science (collect a reading once per body x biome x situation). Shared so the
	client (to show what's collectable here) and the server (to validate a report) agree.

	body      : "Terra" | "Mun" | "Sol"
	situation : "Landed" | "Flying Low" | "Flying High" | "Low Space" | "High Space" | "Solar Orbit"
	biome     : "Plains" | "Desert" | "Snow" | "Mountains" | "Ocean" (Terra, near surface),
	            "Surface" (Mun, landed), or nil (in space / no meaningful biome)
	atmo      : true while inside Terra's atmosphere (so air-only experiments know they can run)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Planet = require(Shared:WaitForChild("Planet"))

local Situations = {}

-- Altitude bands (studs above the body surface).
local TERRA_SPACE_LOW = 40000 -- above the atmosphere up to here = "Low Space", beyond = "High Space"
local MUN_SPACE_LOW = 8000

local function biomeAt(p)
	local m = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	if m < 1e-6 then
		return "Plains"
	end
	local _, material, isOcean = Planet.sample(p.x / m, p.y / m, p.z / m)
	if isOcean or material == Enum.Material.Water then
		return "Ocean"
	elseif material == Enum.Material.Sand then
		return "Desert"
	elseif material == Enum.Material.Snow then
		return "Snow"
	elseif material == Enum.Material.Rock then
		return "Mountains"
	end
	return "Plains"
end

function Situations.of(state, info)
	if not info then
		return nil
	end
	local p = state.position
	local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local alt = r - (info.bodyRadius or 0)
	local landed = info.status == "Landed"
	local bodyId = info.bodyId

	if bodyId == "sun" then
		return { body = "Sol", bodyId = "sun", biome = nil, situation = "Solar Orbit", atmo = false }
	elseif bodyId == "moon" then
		local situation
		if landed then
			situation = "Landed"
		elseif alt < MUN_SPACE_LOW then
			situation = "Low Space"
		else
			situation = "High Space"
		end
		return { body = "Mun", bodyId = "moon", biome = landed and "Surface" or nil, situation = situation, atmo = false }
	end

	-- Terra.
	local atmoTop = Config.ATMOSPHERE.top
	local inAtmo = alt < atmoTop
	local situation
	if landed then
		situation = "Landed"
	elseif inAtmo and alt < atmoTop * 0.5 then
		situation = "Flying Low"
	elseif inAtmo then
		situation = "Flying High"
	elseif alt < TERRA_SPACE_LOW then
		situation = "Low Space"
	else
		situation = "High Space"
	end
	-- Biome is meaningful near the surface (landed or in the air); in space it's nil.
	local biome = (alt < atmoTop) and biomeAt(p) or nil
	return { body = "Terra", bodyId = "planet", biome = biome, situation = situation, atmo = inAtmo }
end

return Situations
