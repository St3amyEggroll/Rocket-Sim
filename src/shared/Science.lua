--[[
	Science
	ReplicatedStorage.Shared.Science

	Biome/situation science: each EXPERIMENT (carried by an instrument part) can be run once per
	{ body, biome, situation } -- the "collected" key. The science earned scales with how exotic
	the situation and body are. Shared so the client previews the reward and the server grants it,
	using the SAME numbers.

	A part grants an experiment via its `experiment` field (= an id in Science.experiments).
]]

local Science = {}

Science.experiments = {
	thermometer = { id = "thermometer", name = "Temperature Scan", base = 3 },
	barometer = { id = "barometer", name = "Pressure Scan", base = 4, needsAtmosphere = true },
	evaSample = { id = "evaSample", name = "Surface Sample", base = 8 }, -- collected on EVA
}

-- Reward = base * situation multiplier * body multiplier (biome only splits the collection key,
-- it doesn't change the value -- every biome of the same situation is worth the same).
local SIT_MULT = {
	["Landed"] = 1.6,
	["Flying Low"] = 0.9,
	["Flying High"] = 1.2,
	["Low Space"] = 1.5,
	["High Space"] = 2.0,
	["Solar Orbit"] = 2.5,
}
local BODY_MULT = {
	Terra = 1.0,
	Mun = 3.0,
	Sol = 5.0,
}

function Science.key(expId, body, biome, situation)
	return table.concat({ expId, body or "?", biome or "-", situation or "?" }, "|")
end

function Science.value(expId, body, situation)
	local e = Science.experiments[expId]
	if not e then
		return 0
	end
	return math.floor(e.base * (SIT_MULT[situation] or 1) * (BODY_MULT[body] or 1) + 0.5)
end

-- Can this experiment run in the given context? (e.g. a barometer needs air.)
function Science.canRun(expId, ctx)
	local e = Science.experiments[expId]
	if not e or not ctx then
		return false
	end
	if e.needsAtmosphere and not ctx.atmo then
		return false
	end
	return true
end

return Science
