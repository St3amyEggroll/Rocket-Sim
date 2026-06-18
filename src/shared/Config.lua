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
	color = Color3.fromRGB(86, 122, 96),
	material = Enum.Material.Rock,
}

-- Where the test craft starts: a clean circular orbit one body-radius up, so the
-- planet reads as a sphere and the whole orbit frames nicely in map view.
Config.START = {
	altitude = 6000, -- studs above surface -> orbital radius = radius + altitude
}

-- Phase 1/2 test craft (a single sphere; infinite fuel for now).
Config.CRAFT = {
	radius = 8, -- render radius (studs)
	color = Color3.fromRGB(225, 228, 235),
	thrustAccel = 150, -- studs/s^2 at full throttle
}

Config.FLIGHT = {
	maxDt = 0.1, -- clamp per-frame dt before time warp is applied
}

Config.FLOATING_ORIGIN = {
	rebaseThreshold = 2000, -- rebase when the craft's render position drifts past this
}

Config.INPUT = {
	throttleRate = 0.6, -- throttle units per second while holding Shift / Ctrl
}

-- On-rails time-warp multipliers (engine off only). "." steps up, "," steps down.
Config.TIMEWARP = {
	levels = { 1, 5, 10, 25, 50, 100 },
}

Config.CAMERA = {
	-- Chase ("flight") view: close on the craft + rider.
	distanceDefault = 90,
	distanceMin = 30,
	distanceMax = 4000,
	-- Map view: framed on the body, pulled back to fit the orbit.
	mapFrameMultiplier = 2.4, -- camera distance = orbit radius * this
	startInMapView = true, -- so you immediately SEE the orbit
	defaultAzimuth = math.rad(45),
	defaultElevation = math.rad(28),

	fieldOfView = 70,
	orbitSensitivity = 0.006, -- radians per pixel of drag
	zoomSensitivity = 0.12, -- fraction per wheel notch
	minElevation = math.rad(-85),
	maxElevation = math.rad(85),
	mapZoomMin = 0.3,
	mapZoomMax = 5,
}

-- Orbit trajectory line (drawn in 3D, visible in map view).
Config.ORBITLINE = {
	segments = 96,
	color = Color3.fromRGB(90, 200, 255),
	apoColor = Color3.fromRGB(255, 120, 120),
	periColor = Color3.fromRGB(120, 255, 180),
	thicknessScale = 0.01, -- * apoapsis radius
	thicknessMin = 50,
	thicknessMax = 500,
}

return Config
