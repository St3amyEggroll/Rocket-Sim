--[[
	Config
	ReplicatedStorage.Shared.Config

	Central tuning. Distances in studs, times in seconds, mu in studs^3/second^2.
	The whole world is kept small enough that the camera never has to pull so far
	back that Roblox culls the scene, while the floating origin keeps the active
	craft near (0,0,0).
]]

local Config = {}

-- The central body. It lives at the SIM origin (0,0,0).
Config.BODY = {
	name = "Terra",
	mu = 5.92e8, -- ~120 s period at the start orbit below
	radius = 2000, -- surface radius (studs)

	oceanColor = Color3.fromRGB(38, 92, 158),
	landColor = Color3.fromRGB(74, 128, 74),
	iceColor = Color3.fromRGB(235, 240, 245),
	continents = 22,
	continentSeed = 1337,
}

-- Start in a circular orbit a couple of body-radii up: the planet reads as a
-- clear ball with space around it, and the map view fits without culling.
Config.START = {
	altitude = 4000, -- studs above surface -> orbital radius = radius + altitude
}

-- Phase 3: build in the VAB, then Launch from the pad and fly to orbit.
Config.LAUNCH = {
	defaultDesign = { "EngineMain", "TankL", "TankL", "Pod" }, -- bottom -> top
	-- Ascent autopilot gravity turn: pitch from straight up to horizontal between
	-- these altitudes.
	turnStartAlt = 250,
	turnEndAlt = 3200,
}

-- The test craft (a small rocket; infinite fuel until Phase 3).
Config.CRAFT = {
	radius = 14, -- bounding radius used for camera framing / map marker
	riderHeight = 7, -- how far up the avatar sits above the craft centre
	thrustAccel = 200, -- studs/s^2 at full throttle
}

Config.FLIGHT = {
	maxDt = 0.1,
}

Config.FLOATING_ORIGIN = {
	-- Large: in this compact world coordinates stay small, so we avoid per-frame
	-- rebasing (which caused jitter). Rebasing still kicks in for very far orbits.
	rebaseThreshold = 60000,
}

Config.INPUT = {
	throttleRate = 0.6,
}

Config.TIMEWARP = {
	levels = { 1, 5, 10, 25, 50, 100 },
}

Config.CAMERA = {
	-- Chase ("flight") view: close on the craft + rider (default so you see it).
	distanceDefault = 70,
	distanceMin = 20,
	distanceMax = 4000,
	startInMapView = false,

	-- Map view: framed on the body, pulled back to fit the orbit.
	mapFrameMultiplier = 2.2,
	defaultAzimuth = math.rad(45),
	defaultElevation = math.rad(22),

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
	thicknessScale = 0.02, -- * apoapsis radius
	thicknessMin = 40,
	thicknessMax = 600,
}

return Config
