--[[
	Config
	ReplicatedStorage.Shared.Config

	Central tuning for the whole sim. All distances are in studs, all times in
	seconds, and mu is in studs^3 / second^2 (see OrbitMechanics).

	The world is deliberately compact so the rendered central body fits within
	Roblox's practical mesh range while the floating origin keeps the active
	craft near (0,0,0).
]]

local Config = {}

-- The central body. It lives at the SIM origin (0,0,0).
Config.BODY = {
	name = "Terra",
	mu = 2.603e9, -- gives ~80 s period at the start orbit below
	radius = 6000, -- surface radius (studs)
	color = Color3.fromRGB(86, 122, 96),
	material = Enum.Material.Rock,
}

-- Where the test craft starts. A clean low circular orbit so coasting is
-- immediately visible; burn prograde to raise it, then circularise.
Config.START = {
	altitude = 1500, -- studs above the surface -> orbital radius = radius + altitude
}

-- The Phase 1 test craft (a single sphere, infinite fuel for now).
Config.CRAFT = {
	radius = 8, -- render radius (studs)
	color = Color3.fromRGB(225, 228, 235),
	thrustAccel = 150, -- studs/s^2 at full throttle (~2x surface gravity)
}

Config.FLIGHT = {
	maxDt = 0.1, -- clamp per-frame dt so a lag spike never throws the orbit
}

Config.FLOATING_ORIGIN = {
	-- Rebase the world when the craft's render position drifts past this many
	-- studs from the render origin.
	rebaseThreshold = 2000,
}

Config.INPUT = {
	throttleRate = 0.6, -- throttle units per second while holding Shift / Ctrl
}

Config.CAMERA = {
	distanceDefault = 120,
	distanceMin = 30,
	distanceMax = 30000,
	fieldOfView = 70,
	orbitSensitivity = 0.006, -- radians per pixel of mouse drag
	zoomSensitivity = 0.12, -- fraction of distance per wheel notch
	minElevation = math.rad(-85),
	maxElevation = math.rad(85),
}

return Config
