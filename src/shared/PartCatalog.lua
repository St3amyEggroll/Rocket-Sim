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
		ecStorage = 150, -- built-in battery (electric charge)
		crewCapacity = 1,
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
	TankM = {
		id = "TankM",
		name = "Fuel Tank (M)",
		category = "fuel",
		mass = 0.26,
		fuel = 3.1,
		height = 5.5,
		radius = 3,
		color = Color3.fromRGB(232, 235, 242),
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
	TankXXL = {
		id = "TankXXL",
		name = "Fuel Tank (XXL)",
		category = "fuel",
		mass = 1.1,
		fuel = 18.0,
		height = 18,
		radius = 3,
		color = Color3.fromRGB(243, 246, 250),
		shape = "tank",
		drag = 0.3,
	},
	NoseCone = {
		id = "NoseCone",
		name = "Nose Cone",
		category = "structure",
		mass = 0.12,
		height = 3,
		radius = 3,
		color = Color3.fromRGB(214, 218, 226),
		shape = "nose",
		drag = 0.04, -- streamlined: very low drag, so it caps a stack and pulls the CoP DOWN
	},
	EngineSmall = {
		id = "EngineSmall",
		name = "Light Engine",
		category = "engine",
		mass = 0.3,
		thrust = 120,
		exhaustVelocity = 210,
		height = 3,
		radius = 2.4,
		color = Color3.fromRGB(104, 106, 114),
		shape = "engine",
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
	EngineXL = {
		id = "EngineXL",
		name = "Heavy-Lift Engine",
		category = "engine",
		mass = 3.2,
		thrust = 1500,
		exhaustVelocity = 205,
		height = 5.5,
		radius = 3,
		color = Color3.fromRGB(66, 68, 76),
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
		fuel = 10.0, -- self-contained: an engine that carries its own solid fuel
		height = 9,
		radius = 1.6,
		color = Color3.fromRGB(206, 200, 188),
		shape = "engine",
		drag = 0.4,
		solid = true, -- ignites when its stage fires and burns at FULL thrust to depletion;
		-- throttle has no effect and it can't be shut off or restarted (a real SRB).
	},
	SRBLarge = {
		id = "SRBLarge",
		name = "Heavy Booster",
		category = "engine",
		mass = 1.7,
		thrust = 820,
		exhaustVelocity = 168,
		fuel = 19.0, -- self-contained solid fuel
		height = 13,
		radius = 1.9,
		color = Color3.fromRGB(212, 206, 196),
		shape = "engine",
		drag = 0.5,
		solid = true, -- ignites on its stage, full thrust to depletion, no throttle/shutoff
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
	Winglet = {
		id = "Winglet",
		name = "Winglet",
		category = "structure",
		mass = 0.08,
		height = 0, -- small control surface; sits where it's placed on the stack
		radius = 2,
		color = Color3.fromRGB(150, 80, 70),
		shape = "fins",
		drag = 0.45, -- modest drag -> gentle stability nudge (lighter than full tail fins)
		radial = true,
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
	LandingLeg = {
		id = "LandingLeg",
		name = "Landing Legs",
		category = "structure",
		mass = 0.12,
		height = 0, -- a side mount; sits at wherever it is on the body
		radius = 1.2,
		color = Color3.fromRGB(170, 172, 180),
		shape = "leg",
		drag = 0.1,
		radial = true, -- surface-attaches to a body's side
		landingLeg = true, -- a set of legs makes touchdown more forgiving
	},
	Thermometer = {
		id = "Thermometer",
		name = "Thermometer",
		category = "structure",
		mass = 0.05,
		height = 0, -- a small side mount
		radius = 0.8,
		color = Color3.fromRGB(182, 186, 194),
		shape = "instrument",
		drag = 0.03,
		radial = true, -- surface-attaches to a body's side
		experiment = "thermometer", -- "Run Experiment" collects a Temperature Scan here
	},
	Barometer = {
		id = "Barometer",
		name = "Barometer",
		category = "structure",
		mass = 0.06,
		height = 0,
		radius = 0.8,
		color = Color3.fromRGB(150, 172, 202),
		shape = "instrument",
		drag = 0.03,
		radial = true,
		experiment = "barometer", -- a Pressure Scan (atmosphere only)
	},
	DockingPort = {
		id = "DockingPort",
		name = "Docking Port",
		category = "structure",
		mass = 0.15,
		height = 1.2, -- a thin ring that stacks on top of the craft (the nose)
		radius = 2.2,
		color = Color3.fromRGB(196, 200, 208),
		shape = "dock",
		drag = 0.06,
		dock = true, -- lets the craft be left in orbit + latch onto another port
	},
	SolarPanel = {
		id = "SolarPanel",
		name = "Solar Panel",
		category = "structure",
		mass = 0.04,
		height = 0,
		radius = 1.2,
		color = Color3.fromRGB(54, 84, 150),
		shape = "solar",
		drag = 0.05,
		radial = true, -- surface-mounts; generates charge when sunlit
		ecGen = 12, -- EC/s at full sun
	},
	Battery = {
		id = "Battery",
		name = "Battery Pack",
		category = "structure",
		mass = 0.05,
		height = 0,
		radius = 1.0,
		color = Color3.fromRGB(150, 154, 162),
		shape = "battery",
		drag = 0.04,
		radial = true,
		ecStorage = 400, -- electric-charge storage
	},
	HeatShield = {
		id = "HeatShield",
		name = "Heat Shield",
		category = "structure",
		mass = 0.3,
		height = 1,
		radius = 3,
		color = Color3.fromRGB(58, 48, 44),
		shape = "heatshield",
		drag = 0.5, -- a broad blunt base (mount it under the craft, base-first reentry)
		ablator = 800, -- soaks up reentry heat until spent
	},
}

-- Display order in the VAB palette.
PartCatalog.order = {
	"Pod",
	"NoseCone",
	"TankS",
	"TankM",
	"TankL",
	"TankXL",
	"TankXXL",
	"EngineSmall",
	"EngineMain",
	"EngineLarge",
	"EngineXL",
	"EngineVac",
	"EngineRadial",
	"SRB",
	"SRBLarge",
	"Fin",
	"Winglet",
	"Parachute",
	"Decoupler",
	"RadialDecoupler",
	"LandingLeg",
	"Thermometer",
	"Barometer",
	"DockingPort",
	"SolarPanel",
	"Battery",
	"HeatShield",
}

function PartCatalog.get(id)
	return PartCatalog.parts[id]
end

return PartCatalog
