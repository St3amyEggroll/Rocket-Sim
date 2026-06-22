--[[
	CraftStats
	ReplicatedStorage.Shared.CraftStats

	Pure stat math for a craft design. The design is an array of part definitions
	ordered BOTTOM -> TOP (index 1 = bottom = first to fire).

	Serial staging model: a stage = one engine plus the fuel tanks above it (up to
	the next engine). Command/structure parts are "payload" - never jettisoned, and
	carried by every stage. Jettisoning a stage drops its engine + tanks only.

	Delta-v per stage (Tsiolkovsky): dv = ve * ln(m0 / mf), where m0 includes the
	stage's full fuel and mf is the same dry, both carrying everything above.
]]

local CraftStats = {}

function CraftStats.analyze(defs, surfaceGravity)
	surfaceGravity = surfaceGravity or 0

	local stages = {}
	local stageOfPart = {} -- design index -> stage number (0 = payload)
	local payloadMass = 0
	local current = nil
	local stageNum = 0

	for i, def in ipairs(defs) do
		if def.category == "engine" then
			stageNum += 1
			current = {
				thrust = def.thrust or 0,
				ve = def.exhaustVelocity or 1,
				dryMass = def.mass or 0,
				fuel = 0,
			}
			stages[stageNum] = current
			stageOfPart[i] = stageNum
		elseif def.category == "fuel" then
			if current then
				current.dryMass += def.mass or 0
				current.fuel += def.fuel or 0
				stageOfPart[i] = stageNum
			else
				-- Fuel below the bottom engine cannot feed up: dead weight.
				payloadMass += (def.mass or 0) + (def.fuel or 0)
				stageOfPart[i] = 0
			end
		elseif def.category == "structure" and current then
			-- Structure (fins, decouplers) belongs to its stage and drops with it.
			current.dryMass += def.mass or 0
			stageOfPart[i] = stageNum
		else
			-- Command pods (and anything above the bottom engine) are payload.
			payloadMass += def.mass or 0
			stageOfPart[i] = 0
		end
	end

	local n = #stages
	local above = payloadMass
	for k = n, 1, -1 do
		stages[k].massAbove = above
		above += stages[k].dryMass + stages[k].fuel
	end
	local totalMass = above

	local totalDV = 0
	for k = 1, n do
		local s = stages[k]
		local m0 = s.massAbove + s.dryMass + s.fuel
		local mf = s.massAbove + s.dryMass
		s.deltaV = (s.fuel > 0 and mf > 0) and (s.ve * math.log(m0 / mf)) or 0
		totalDV += s.deltaV
	end

	local launchTWR = 0
	if n > 0 and surfaceGravity > 0 and totalMass > 0 then
		launchTWR = stages[1].thrust / (totalMass * surfaceGravity)
	end

	return {
		stages = stages,
		stageOfPart = stageOfPart,
		stageCount = n,
		payloadMass = payloadMass,
		totalMass = totalMass,
		totalDeltaV = totalDV,
		launchTWR = launchTWR,
	}
end

return CraftStats
