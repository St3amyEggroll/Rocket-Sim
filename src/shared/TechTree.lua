--[[
	TechTree
	ReplicatedStorage.Shared.TechTree

	The tech progression, shared by client + server so they agree on costs / parts.

	Tiers are an ordered LADDER: tier 1 ("Basics") is free and unlocked from the start. A
	tier becomes BUYABLE once the previous tier is unlocked; unlocking it costs `cost` science
	and grants all its parts -- which opens the next tier. Science is earned from one-time
	milestones (firsts), defined below.
]]

local TechTree = {}

TechTree.tiers = {
	{ id = "basics", name = "Basics", cost = 0, parts = { "Pod", "NoseCone", "TankS", "TankL", "EngineMain", "Fin", "Parachute" } },
	{ id = "staging", name = "Staging", cost = 6, parts = { "Decoupler", "TankXL" } },
	{ id = "boosters", name = "Boosters", cost = 12, parts = { "SRB", "RadialDecoupler", "EngineRadial" } },
	{ id = "heavy", name = "Heavy Lift", cost = 20, parts = { "EngineLarge", "TankXXL" } },
	{ id = "landing", name = "Landing & Vacuum", cost = 30, parts = { "LandingLeg", "EngineVac" } },
	{ id = "advanced", name = "Advanced", cost = 45, parts = { "EngineXL" } },
}

TechTree.milestones = {
	{ id = "alt5k", science = 4, label = "Reach 5 km altitude" },
	{ id = "alt25k", science = 6, label = "Reach 25 km altitude" },
	{ id = "space", science = 6, label = "Leave the atmosphere" },
	{ id = "orbit", science = 14, label = "Reach a stable orbit" },
	{ id = "munSOI", science = 20, label = "Reach the Mun" },
	{ id = "munLand", science = 30, label = "Land on the Mun" },
	{ id = "solar", science = 50, label = "Reach solar orbit" },
}

function TechTree.milestoneScience(id)
	for _, m in ipairs(TechTree.milestones) do
		if m.id == id then
			return m.science
		end
	end
	return nil
end

function TechTree.tierById(id)
	for i, t in ipairs(TechTree.tiers) do
		if t.id == id then
			return t, i
		end
	end
	return nil
end

-- The id of the tier before `id` (nil for the first tier).
function TechTree.prevTierId(id)
	for i, t in ipairs(TechTree.tiers) do
		if t.id == id then
			return (i > 1) and TechTree.tiers[i - 1].id or nil
		end
	end
	return nil
end

-- Set { partId = true } of every part granted by the unlocked-tier set.
function TechTree.unlockedParts(unlocked)
	local set = {}
	for _, t in ipairs(TechTree.tiers) do
		if unlocked[t.id] then
			for _, p in ipairs(t.parts) do
				set[p] = true
			end
		end
	end
	return set
end

return TechTree
