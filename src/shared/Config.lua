--[[
	Config
	ReplicatedStorage.Shared.Config

	The planet is a grass Ball part (the always-visible LOD) wrapped in real
	Roblox terrain laid by render distance over a fixed Perlin heightfield
	(Shared.Planet). It sits at the world origin; the craft flies around it with
	OrbitMechanics. Units: studs / seconds, mu in studs^3/s^2.
]]

local Config = {}

Config.BODY = {
	name = "Terra",
	radius = 1000, -- a real Ball part (<=1024 radius) so it never culls
	mu = 1.5e7, -- surface gravity ~15 studs/s^2
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
	landSpeed = 32, -- touchdown faster than this (studs/s) counts as a crash
}

-- Atmosphere: an exponential air layer that produces aerodynamic drag (an extra
-- acceleration fed to OrbitMechanics.integrate) and reentry heating. Inside it the
-- flight is integrated numerically (drag is not a conic force) and time warp is
-- pinned to 1x, exactly like KSP. Above ATMOSPHERE.top the air is gone and coasting
-- is back on analytic rails.
Config.ATMOSPHERE = {
	top = 600, -- studs above sea level where the air becomes negligible
	scaleHeight = 130, -- air density e-folds (1/e) over this many studs of altitude
	dragCoeff = 0.008, -- drag accel = dragCoeff * densityFrac * speed^2 * dragArea / mass
	reentryQ = 1800, -- densityFrac*speed^2 above this begins reentry heating FX
	maxReentryQ = 9000, -- ...and it saturates here
	color = Color3.fromRGB(120, 170, 255), -- atmosphere haze tint
}

Config.CRAFT = {
	radius = 14,
	riderHeight = 7,
}

Config.LAUNCH = {
	defaultDesign = { "EngineMain", "LandingLegs", "TankL", "TankL", "Pod" }, -- bottom -> top
	turnStartAlt = 150,
	turnEndAlt = 1200,
}

Config.CONTROL = {
	pitchRate = 1.3,
	yawRate = 1.3,
	rollRate = 2.0,
	sasSlew = 3.0,
}

-- Landing legs (cosmetic + define a wide, stable support base for landing).
Config.LEGS = {
	count = 3,
	standHeight = 5, -- the craft base rests this high on the legs
	spread = 2.2, -- foot horizontal distance from the axis = bottomRadius * spread
	thickness = 0.7,
	footRadius = 1.1,
	color = Color3.fromRGB(70, 74, 84),
}

-- Touchdown rules. A landing is clean only if the craft is upright enough, slow
-- enough sideways, and on gentle enough ground. Landing legs make all of these far
-- more forgiving; without legs the craft tips easily (KSP-style). A failed landing
-- tips the craft over and flags Crashed.
Config.LANDING = {
	tipDuration = 1.1, -- seconds for the tip-over animation
	maxTiltLegs = math.rad(35), -- nose tilt from vertical allowed at touchdown (with legs)
	maxHorizLegs = 18, -- horizontal speed allowed (studs/s)
	maxSlopeLegs = math.rad(22), -- ground slope allowed
	maxTiltBare = math.rad(12), -- much tippier without legs
	maxHorizBare = 6,
	maxSlopeBare = math.rad(8),
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
