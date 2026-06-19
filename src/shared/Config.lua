--[[
	Config
	ReplicatedStorage.Shared.Config

	Central tuning. Distances in studs, time in seconds, mu in studs^3/second^2.
]]

local Config = {}

Config.BODY = {
	name = "Terra",
	mu = 1.6e10, -- surface gravity ~40 studs/s^2 at the 20k radius
	radius = 20000,
	oceanColor = Color3.fromRGB(38, 92, 158),
	landColor = Color3.fromRGB(74, 128, 74),
	iceColor = Color3.fromRGB(235, 240, 245),
	continents = 12,
	continentSeed = 1337,
}

Config.CRAFT = {
	radius = 14,
	riderHeight = 7,
}

Config.LAUNCH = {
	defaultDesign = { "EngineMain", "TankL", "TankL", "Pod" }, -- bottom -> top
	turnStartAlt = 1500,
	turnEndAlt = 12000,
}

Config.FLIGHT = {
	maxDt = 0.1,
}

-- Manual attitude control (KSP-style): WASD pitch/yaw, QE roll, in rad/s.
Config.CONTROL = {
	pitchRate = 1.3,
	yawRate = 1.3,
	rollRate = 2.0,
	sasSlew = 3.0, -- how fast auto-orient (SAS) rotates toward its target
}

Config.FLOATING_ORIGIN = {
	rebaseThreshold = 150000,
}

Config.INPUT = {
	throttleRate = 0.6,
}

Config.TIMEWARP = {
	levels = { 1, 5, 10, 25, 50, 100 },
}

Config.CAMERA = {
	distanceDefault = 130,
	distanceMin = 35,
	distanceMax = 20000,
	startInMapView = false,
	fieldOfView = 70,
	orbitSensitivity = 0.006,
	zoomSensitivity = 0.12,
	minElevation = math.rad(-80),
	maxElevation = math.rad(80),
	mapZoomMin = 0.4,
	mapZoomMax = 4,
}

-- Rendering: the body is drawn as a real Ball part placed camera-relative so it
-- can never be culled and always shows at the correct angular size.
Config.RENDER = {
	proxyRadius = 1000, -- fixed render radius of the planet proxy ball (<=1024)
	proxyDistMin = 1000,
	proxyDistMax = 6000, -- keep the proxy comfortably inside render range
	mapPlanetRadius = 900,
	mapViewRadius = 3000,
	mapCamMultiplier = 2.0,
	parkY = 400000,
}

Config.ORBITLINE = {
	segments = 90,
	color = Color3.fromRGB(90, 200, 255),
	apoColor = Color3.fromRGB(255, 120, 120),
	periColor = Color3.fromRGB(120, 255, 180),
	craftColor = Color3.fromRGB(255, 240, 120),
}

return Config
