--[[
	Config
	ReplicatedStorage.Shared.Config

	The planet is a grass mesh sphere (the always-visible LOD) wrapped in real
	Roblox terrain laid by render distance over a fixed Perlin heightfield
	(Shared.Planet). It sits at the world origin; the craft flies around it with
	OrbitMechanics. Units: studs / seconds, mu in studs^3/s^2.
]]

local Config = {}

Config.BODY = {
	name = "Terra",
	radius = 15000, -- drawn as a scaled mesh sphere (PlanetRenderer)
	mu = 3.375e9, -- surface gravity ~15 studs/s^2 (g = mu / radius^2)
	seed = 1337,
	grassColor = Color3.fromRGB(86, 140, 74),
	hillColor = Color3.fromRGB(74, 124, 66),
}

-- Render-distance terrain. The planet's surface is a single deterministic
-- Perlin heightfield (see Shared.Planet); it is NOT generated on the fly. Real
-- Roblox terrain is laid in fixed world-space chunks that load when within
-- renderDistance of the craft and unload when beyond it - loaded chunks are
-- never re-laid. Beyond the terrain, the grass Ball is the low-detail LOD.
Config.TERRAIN = {
	chunkSize = 220, -- world-space cube edge of one terrain chunk
	renderDistance = 640, -- terrain is shown within this many studs of the craft
	spacing = 30, -- grid step between crust fill-balls inside a chunk
	ballRadius = 26, -- fill-ball radius (overlaps neighbours into a shell)
	reliefAmp = 18, -- +/- studs of Perlin relief on the surface
	reliefFreq = 0.012, -- base Perlin frequency (smaller = broader hills)
	streamInAlt = 620, -- at/below this altitude terrain begins loading
	streamOutAlt = 900, -- above this altitude all terrain unloads (Ball LOD only)
	ballsPerYield = 40, -- fill-balls placed per frame while a chunk loads in
	scanInterval = 0.15, -- seconds between render-distance rescans
}

Config.FLIGHT = {
	maxDt = 0.1,
	crashSpeed = 10, -- touchdown faster than this (studs/s) destroys the craft
}

-- Atmosphere: an exponential air layer that produces aerodynamic drag (an extra
-- acceleration fed to OrbitMechanics.integrate) and reentry heating. Inside it the
-- flight is integrated numerically (drag is not a conic force) and time warp is
-- pinned to 1x, exactly like KSP. Above ATMOSPHERE.top the air is gone and coasting
-- is back on analytic rails.
Config.ATMOSPHERE = {
	top = 2500, -- studs above sea level where the air becomes negligible
	scaleHeight = 520, -- air density e-folds (1/e) over this many studs of altitude
	dragCoeff = 0.004, -- drag accel = dragCoeff * densityFrac * speed^2 * dragArea / mass
	reentryQ = 8000, -- densityFrac*speed^2 above this begins reentry heating FX
	maxReentryQ = 40000, -- ...and it saturates here
	momentScale = 1.4, -- multiplier on aerodynamic torque (flip aggressiveness)
	color = Color3.fromRGB(120, 170, 255), -- atmosphere haze tint
}

-- Sky. The world transitions from a bright blue Earth-like sky in the atmosphere to
-- a dark, starry space sky as you climb, blended by altitude (SkyController). The Sun
-- and Moon are Roblox's native celestial bodies (with procedural stars), so they
-- always render no matter how far the craft is from the world origin.
Config.SKY = {
	starCount = 3200,
	blendStartAlt = 300, -- at/below this altitude the sky is fully atmospheric (blue)
	blendEndAlt = 2800, -- at/above this altitude the sky is fully space (dark + stars)
	dayClockTime = 14, -- atmosphere: midday sun, blue sky
	spaceClockTime = 22.5, -- space: night side, stars out
	groundBrightness = 2.6,
	spaceBrightness = 1.8,
	groundAmbient = Color3.fromRGB(80, 84, 96),
	spaceAmbient = Color3.fromRGB(30, 32, 42), -- not pitch black, so the craft stays visible
	groundOutdoor = Color3.fromRGB(150, 152, 160),
	spaceOutdoor = Color3.fromRGB(44, 46, 58),
	atmoDensity = 0.32, -- Atmosphere instance density at sea level
}

Config.CRAFT = {
	radius = 14,
	riderHeight = 7,
}

Config.LAUNCH = {
	defaultDesign = { "EngineMain", "Fin", "TankL", "TankL", "Pod" }, -- bottom -> top
	turnStartAlt = 150,
	turnEndAlt = 1200,
}

-- Attitude is now a real rigid-body rotation: the craft has angular velocity and a
-- moment of inertia, and torques (reaction wheels + engine gimbal for control,
-- aerodynamics for stability) spin it. Reaction-wheel authority is deliberately
-- weak (KSP-hardcore): an aerodynamically unstable rocket WILL flip and must be
-- fixed with fins / weight, not muscled straight.
Config.CONTROL = {
	reactionWheelAccel = 0.35, -- rad/s^2 of control authority from reaction wheels
	gimbalAccel = 0.7, -- + this * throttle of authority while the engine is burning
	sasKp = 5.0, -- SAS pointing stiffness (toward the selected marker)
	sasKd = 3.0, -- SAS rate damping
	aeroDamp = 0.6, -- passive aerodynamic pitch damping per unit air density
	maxOmega = 12, -- rad/s angular-velocity safety cap
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
	distanceDefault = 130,
	distanceMin = 30,
	distanceMax = 9000,
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
