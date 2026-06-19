--[[
	PartCatalog
	ReplicatedStorage.Shared.PartCatalog

	Parts are DATA. Each entry describes mass, fuel, thrust, drag, size and how to
	render it. CraftStats turns a list of these into mass / staging / delta-v, and
	the flight loop turns the active engine's thrust into acceleration.

	Units (consistent with OrbitMechanics): mass in "tonnes" (arbitrary), thrust in
	mass*studs/s^2, exhaustVelocity in studs/s, fuel in mass units. Acceleration =
	thrust / mass (studs/s^2); fuel burn rate = thrust / exhaustVelocity.

	category: "command" | "fuel" | "engine" | "structure"
	shape (render hint): "pod" | "tank" | "engine"
]]

local PartCatalog = {}

PartCatalog.parts = {
	Pod = {
		id = "Pod",
		name = "Command Pod",
		category = "command",
		mass = 0.6,
		height = 4,
		radius = 3,
		color = Color3.fromRGB(205, 210, 220),
		shape = "pod",
		drag = 0.2,
	},
	TankS = {
		id = "TankS",
		name = "Fuel Tank (S)",
		category = "fuel",
		mass = 0.18,
		fuel = 2.0,
		height = 4,
		radius = 3,
		color = Color3.fromRGB(228, 231, 238),
		shape = "tank",
		drag = 0.2,
	},
	TankL = {
		id = "TankL",
		name = "Fuel Tank (L)",
		category = "fuel",
		mass = 0.35,
		fuel = 4.5,
		height = 7,
		radius = 3,
		color = Color3.fromRGB(236, 239, 245),
		shape = "tank",
		drag = 0.2,
	},
	EngineMain = {
		id = "EngineMain",
		name = "Main Engine",
		category = "engine",
		mass = 0.6,
		thrust = 1200,
		exhaustVelocity = 1050,
		height = 3.5,
		radius = 3,
		color = Color3.fromRGB(92, 94, 102),
		shape = "engine",
		drag = 0.3,
	},
	EngineVac = {
		id = "EngineVac",
		name = "Vacuum Engine",
		category = "engine",
		mass = 0.5,
		thrust = 700,
		exhaustVelocity = 1500,
		height = 3.2,
		radius = 2.4,
		color = Color3.fromRGB(120, 100, 70),
		shape = "engine",
		drag = 0.3,
	},
}

-- Display order in the VAB palette.
PartCatalog.order = { "Pod", "TankS", "TankL", "EngineMain", "EngineVac" }

function PartCatalog.get(id)
	return PartCatalog.parts[id]
end

return PartCatalog
