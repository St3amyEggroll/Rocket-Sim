--[[
	Config
	ReplicatedStorage.Shared.Config

	Central tuning. Distances in studs, times in seconds, mu in studs^3/second^2.
	The world is compact so the rendered body fits Roblox's practical mesh range
	while the floating origin keeps the active craft near (0,0,0).
]]

local Config = {}

-- The central body. It lives at the SIM origin (0,0,0).
Config.BODY = {
	name = "Terra",
	mu = 2.603e9,
	radius = 6000, -- surface radius (studs)

	-- Look of the planet (rendered as ocean sphere + continent / ice slabs).
	oceanColor = Color3.fromRGB(38, 92, 158),
	landColor = Color3.fromRGB(74, 128, 74),
	iceColor = Color3.fromRGB(235, 240, 245),
	continents = 22,
	continentSeed = 1337,
}

-- Start in a circular orbit well above the surface, so the planet reads as a
-- ball in the distance (not a wall filling the screen).
Config.START = {
	altitude = 12000, -- studs above surface -> orbital radius = radius + altitude
}

-- The test craft (a small rocket; infinite fuel until Phase 3).
Config.CRAFT = {
	radius = 14, -- bounding radius used for camera framing / map marker
	riderHeight = 7, -- how far up the avatar sits above the craft centre
	thrustAccel = 150, -- studs/s^2 at full throttle
}

Config.FLIGHT = {
	maxDt = 0.1, -- clamp per-frame dt before time warp is applied
}

Config.FLOATING_ORIGIN = {
	rebaseThreshold = 2000,
}

Config.INPUT = {
	throttleRate = 0.6,
}

Config.TIMEWARP = {
	levels = { 1, 5, 10, 25, 50, 100 },
}

Config.CAMERA = {
	-- Chase ("flight") view: close on the craft + rider. This is the default so
	-- you immediately see the rocket.
	distanceDefault = 70,
	distanceMin = 20,
	distanceMax = 5000,
	startInMapView = false,

	-- Map view: framed on the body, pulled back to fit the orbit.
	mapFrameMultiplier = 2.4,
	defaultAzimuth = math.rad(45),
	defaultElevation = math.rad(20),

	fieldOfView = 70,
	orbitSensitivity = 0.006,
	zoomSensitivity = 0.12,
	minElevation = math.rad(-85),
	maxElevation = math.rad(85),
	mapZoomMin = 0.3,
	mapZoomMax = 5,
}

-- Orbit trajectory overlay (map view only).
Config.ORBITLINE = {
	segments = 96,
	color = Color3.fromRGB(90, 200, 255),
	apoColor = Color3.fromRGB(255, 120, 120),
	periColor = Color3.fromRGB(120, 255, 180),
	craftColor = Color3.fromRGB(255, 240, 120),
	thicknessScale = 0.01,
	thicknessMin = 50,
	thicknessMax = 500,
}

return Config
