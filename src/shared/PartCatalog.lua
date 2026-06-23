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
	TankXL = {
		id = "TankXL",
		name = "Fuel Tank (XL)",
		category = "fuel",
		mass = 0.6,
		fuel = 9.0,
		height = 12,
		radius = 3,
		color = Color3.fromRGB(240, 243, 248),
		shape = "tank",
		drag = 0.25,
	},
	EngineMain = {
		id = "EngineMain",
		name = "Main Engine",
		category = "engine",
		mass = 0.6,
		thrust = 250,
		exhaustVelocity = 180,
		height = 3.5,
		radius = 3,
		color = Color3.fromRGB(92, 94, 102),
		shape = "engine",
		drag = 0.3,
	},
	EngineLarge = {
		id = "EngineLarge",
		name = "Heavy Engine",
		category = "engine",
		mass = 1.4,
		thrust = 620,
		exhaustVelocity = 195,
		height = 4.5,
		radius = 3,
		color = Color3.fromRGB(78, 80, 88),
		shape = "engine",
		drag = 0.3,
	},
	EngineVac = {
		id = "EngineVac",
		name = "Vacuum Engine",
		category = "engine",
		mass = 0.5,
		thrust = 150,
		exhaustVelocity = 300,
		height = 3.2,
		radius = 2.4,
		color = Color3.fromRGB(120, 100, 70),
		shape = "engine",
		drag = 0.3,
	},
	EngineRadial = {
		id = "EngineRadial",
		name = "Radial Engine",
		category = "engine",
		mass = 0.25,
		thrust = 95,
		exhaustVelocity = 220,
		height = 2.6,
		radius = 0.8,
		color = Color3.fromRGB(150, 120, 84),
		shape = "engine",
		drag = 0.2,
		radial = true, -- bolts to a body's side; draws fuel from the part it's bolted to
	},
	SRB = {
		id = "SRB",
		name = "Solid Booster",
		category = "engine",
		mass = 0.9,
		thrust = 430,
		exhaustVelocity = 160,
		fuel = 7.0, -- self-contained: an engine that carries its own solid fuel
		height = 9,
		radius = 1.6,
		color = Color3.fromRGB(206, 200, 188),
		shape = "engine",
		drag = 0.4,
	},
	Parachute = {
		id = "Parachute",
		name = "Parachute",
		category = "structure",
		mass = 0.1,
		height = 1.2,
		radius = 2,
		color = Color3.fromRGB(220, 96, 76),
		shape = "parachute",
		drag = 0.2, -- stowed
		chuteDrag = 300, -- huge extra drag once deployed (in air) -> a soft landing
		parachute = true, -- deploys when its stage fires
	},
	Fin = {
		id = "Fin",
		name = "Tail Fins",
		category = "structure",
		mass = 0.2,
		height = 0, -- blades wrap the body at wherever they sit in the stack
		radius = 3,
		color = Color3.fromRGB(150, 80, 70),
		shape = "fins",
		drag = 0.9, -- lots of drag where they sit -> pulls the centre of pressure there
		radial = true, -- surface-attaches to a body's side
	},
	Decoupler = {
		id = "Decoupler",
		name = "Decoupler",
		category = "structure",
		mass = 0.15,
		height = 1, -- a thin band; everything below it drops as a stage when fired
		radius = 3,
		color = Color3.fromRGB(94, 96, 104),
		shape = "decoupler",
		drag = 0.15,
		decoupler = true, -- a separation point: firing its stage cuts the stack here
	},
	RadialDecoupler = {
		id = "RadialDecoupler",
		name = "Radial Decoupler",
		category = "structure",
		mass = 0.1,
		height = 2, -- a small side mount; its booster subtree drops when fired
		radius = 1,
		color = Color3.fromRGB(120, 92, 72),
		shape = "decoupler",
		drag = 0.1,
		radial = true, -- surface-attaches to a body's side (holds a side booster)
		decoupler = true, -- a separation point: firing its stage drops the booster on it
		-- ...but other parts may still STACK onto it (build the booster off its node).
	},
}

-- Display order in the VAB palette.
PartCatalog.order = {
	"Pod",
	"TankS",
	"TankL",
	"TankXL",
	"EngineMain",
	"EngineLarge",
	"EngineVac",
	"EngineRadial",
	"SRB",
	"Fin",
	"Parachute",
	"Decoupler",
	"RadialDecoupler",
}

function PartCatalog.get(id)
	return PartCatalog.parts[id]
end

return PartCatalog
