--[[
	TechTree
	ReplicatedStorage.Shared.TechTree

	A BRANCHING tech graph (KSP-style), shared by client + server so they agree on costs / parts.

	Each NODE grants its parts when researched. A node becomes buyable once ANY of its
	prerequisite nodes is researched -- so the tree fans out and you choose your own path through
	the branches (aero / fuel / engineering, then heavier lift, vacuum, radial, etc.). The root
	("basics") is free and unlocked from the start. Science is earned from one-time milestones.

	col/row are the node's grid position for the Research graph layout (col = depth from the
	root, row = vertical lane). Edges are drawn from each node back to its `requires`.
]]

local TechTree = {}

TechTree.nodes = {
	-- Root: the bare minimum to fly. Free + unlocked from the start (id kept as "basics" so
	-- existing saves / the default profile's { basics = true } still seed the root).
	{ id = "basics", name = "Start", col = 0, row = 3, cost = 0, requires = {},
		parts = { "Pod", "EngineMain", "TankS", "Parachute", "Thermometer" } },

	-- First ring: three independent directions branching off the root.
	{ id = "aerodynamics", name = "Aerodynamics", col = 1, row = 1, cost = 3, requires = { "basics" },
		parts = { "Fin", "Winglet", "NoseCone", "Barometer" } },
	{ id = "generalRocketry", name = "General Rocketry", col = 1, row = 3, cost = 4, requires = { "basics" },
		parts = { "TankM", "TankL", "EngineSmall" } },
	{ id = "engineering", name = "Engineering", col = 1, row = 5, cost = 5, requires = { "basics" },
		parts = { "Decoupler" } },

	-- Second ring.
	{ id = "landing", name = "Landing", col = 2, row = 0, cost = 10, requires = { "aerodynamics" },
		parts = { "LandingLeg" } },
	{ id = "docking", name = "Docking Tech", col = 2, row = 1, cost = 16, requires = { "generalRocketry" },
		parts = { "DockingPort" } },
	{ id = "fuelSystems", name = "Fuel Systems", col = 2, row = 2, cost = 8, requires = { "generalRocketry" },
		parts = { "TankXL" } },
	{ id = "heavyRocketry", name = "Heavy Rocketry", col = 2, row = 3, cost = 12, requires = { "generalRocketry" },
		parts = { "EngineLarge" } },
	{ id = "boosters", name = "Boosters", col = 2, row = 5, cost = 10, requires = { "engineering" },
		parts = { "SRB", "SRBLarge", "RadialDecoupler" } },

	-- Third ring.
	{ id = "advFuelSystems", name = "Adv. Fuel Systems", col = 3, row = 2, cost = 16, requires = { "fuelSystems" },
		parts = { "TankXXL" } },
	{ id = "vacuumTech", name = "Vacuum Propulsion", col = 3, row = 3, cost = 20, requires = { "heavyRocketry" },
		parts = { "EngineVac" } },
	{ id = "radialPropulsion", name = "Radial Propulsion", col = 3, row = 5, cost = 14, requires = { "boosters" },
		parts = { "EngineRadial" } },

	-- Endgame.
	{ id = "heavyPropulsion", name = "Heavy Propulsion", col = 4, row = 3, cost = 30, requires = { "vacuumTech" },
		parts = { "EngineXL" } },
}

TechTree.milestones = {
	{ id = "alt5k", science = 4, label = "Reach 5 km altitude" },
	{ id = "alt25k", science = 6, label = "Reach 25 km altitude" },
	{ id = "space", science = 6, label = "Leave the atmosphere" },
	{ id = "orbit", science = 14, label = "Reach a stable orbit" },
	{ id = "munSOI", science = 20, label = "Reach the Mun" },
	{ id = "munLand", science = 30, label = "Land on the Mun" },
	{ id = "solar", science = 50, label = "Reach solar orbit" },
	{ id = "dock", science = 25, label = "Dock two craft" },
}

function TechTree.milestoneScience(id)
	for _, m in ipairs(TechTree.milestones) do
		if m.id == id then
			return m.science
		end
	end
	return nil
end

function TechTree.nodeById(id)
	for _, n in ipairs(TechTree.nodes) do
		if n.id == id then
			return n
		end
	end
	return nil
end

-- A node is buyable once ANY prerequisite is researched (the root has none -> always met). This
-- "reachable via any researched parent" rule is what lets branches be taken in any order and
-- converge later.
function TechTree.requiresMet(node, unlocked)
	if not node.requires or #node.requires == 0 then
		return true
	end
	for _, r in ipairs(node.requires) do
		if unlocked[r] then
			return true
		end
	end
	return false
end

-- Set { partId = true } of every part granted by the researched-node set.
function TechTree.unlockedParts(unlocked)
	local set = {}
	for _, n in ipairs(TechTree.nodes) do
		if unlocked[n.id] then
			for _, p in ipairs(n.parts) do
				set[p] = true
			end
		end
	end
	return set
end

return TechTree
