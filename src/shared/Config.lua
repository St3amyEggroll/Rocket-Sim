--[[
	Config
	ReplicatedStorage.Shared.Config

	The planet is a real Roblox-Terrain grass sphere small enough to render whole
	(no streaming). It sits at the world origin; the craft flies around it with
	OrbitMechanics. Units: studs / seconds, mu in studs^3/s^2.
]]

local Config = {}

Config.BODY = {
	name = "Terra",
	radius = 500, -- whole-sphere terrain ball
	mu = 3.75e6, -- surface gravity ~15 studs/s^2
	seed = 1337,
	grassColor = Color3.fromRGB(86, 140, 74),
	waterColor = Color3.fromRGB(40, 96, 150),
	rockColor = Color3.fromRGB(120, 116, 108),
	sandColor = Color3.fromRGB(214, 198, 150),
}

Config.CRAFT = {
	radius = 14,
	riderHeight = 7,
}

Config.LAUNCH = {
	defaultDesign = { "EngineMain", "TankL", "TankL", "Pod" }, -- bottom -> top
	turnStartAlt = 80,
	turnEndAlt = 600,
}

Config.FLIGHT = {
	maxDt = 0.1,
}

Config.CONTROL = {
	pitchRate = 1.3,
	yawRate = 1.3,
	rollRate = 2.0,
	sasSlew = 3.0,
}

Config.FLOATING_ORIGIN = {
	rebaseThreshold = 1e9, -- the world is small; never rebase (terrain is fixed)
}

Config.INPUT = {
	throttleRate = 0.6,
}

Config.TIMEWARP = {
	levels = { 1, 5, 10, 25, 50, 100 },
}

Config.CAMERA = {
	distanceDefault = 120,
	distanceMin = 30,
	distanceMax = 6000,
	startInMapView = false,
	fieldOfView = 70,
	orbitSensitivity = 0.006,
	zoomSensitivity = 0.12,
	minElevation = math.rad(-80),
	maxElevation = math.rad(80),
	mapZoomMin = 0.4,
	mapZoomMax = 4,
	mapCamMultiplier = 2.4,
}

Config.ORBITLINE = {
	segments = 90,
	color = Color3.fromRGB(90, 200, 255),
	apoColor = Color3.fromRGB(255, 120, 120),
	periColor = Color3.fromRGB(120, 255, 180),
	craftColor = Color3.fromRGB(255, 240, 120),
}

return Config
