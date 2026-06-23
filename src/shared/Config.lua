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
	radius = 10000, -- drawn as a scaled mesh sphere (PlanetRenderer)
	mu = 1.5e9, -- surface gravity ~15 studs/s^2 (g = mu / radius^2)
	seed = 1337,
	grassColor = Color3.fromRGB(86, 140, 74),
	hillColor = Color3.fromRGB(74, 124, 66),
	lodColor = Color3.fromRGB(56, 102, 146), -- distant ocean-blue tint (reads as a world from space)
}

-- A second body: a Mun-style moon orbiting Terra with its own sphere of influence
-- (SOI) and gravity. Patched conics: outside the SOI you orbit Terra; cross into the
-- SOI and the flight switches to a two-body orbit around the moon. It orbits in the
-- EQUATORIAL (X/Z) plane, coplanar with an equatorial launch -- fly there with a
-- well-timed prograde burn. Airless: land it propulsively (no chutes).
Config.MOON = {
	name = "Mun",
	radius = 2600,
	mu = 2.0e7, -- surface gravity ~3 studs/s^2
	orbitRadius = 60000, -- distance from Terra's centre (render-safe, no origin rebase)
	phase = 1.4, -- starting angle in its orbit (radians)
	color = Color3.fromRGB(150, 150, 158),
	-- soi is derived in FlightController: orbitRadius * (mu/Terra.mu)^(2/5)
}

-- Render-distance terrain. The planet's surface is a single deterministic Perlin
-- biome+heightfield (see Shared.Planet); it is NOT generated on the fly. Real Roblox
-- terrain is laid in fixed world-space chunks that load when within renderDistance of
-- the craft and unload when beyond it. Each surface cell is a flat-topped COLUMN
-- (FillBlock, oriented to the local up) rather than a ball -- Roblox's terrain
-- smoothing rounds them into smooth ground, not bumpy spheres. Beyond the terrain,
-- the mesh-sphere body is the low-detail LOD.
Config.TERRAIN = {
	chunkSize = 220, -- world-space cube edge of one terrain chunk
	renderDistance = 960, -- terrain is shown within this many studs of the craft
	spacing = 18, -- grid step between terrain columns inside a chunk
	footprint = 26, -- column footprint (overlaps neighbours so there are no gaps)
	crustThickness = 26, -- how deep each column fills below its surface
	streamInAlt = 620, -- at/below this altitude terrain begins loading
	streamOutAlt = 900, -- above this altitude all terrain unloads (LOD only)
	fillsPerYield = 60, -- terrain columns placed per frame while a chunk loads in
	scanInterval = 0.15, -- seconds between render-distance rescans
}

-- Biomes. A low-frequency "elevation" Perlin field shapes continents/oceans and a
-- separate "temperature" field splits the temperate land into plains/desert/cold.
-- Plains are deliberately the widest band. Each biome sets its own surface height
-- (mostly flat, mountains the exception) and Roblox material. Frequencies are tuned
-- for medium biomes (~1-1.5k studs) so a landing usually shows one biome + a border.
Config.BIOMES = {
	elevFreq = 0.0008, -- continents/oceans (smaller = bigger biomes)
	tempFreq = 0.0011, -- temperature split for land biomes
	detailFreq = 0.02, -- fine within-biome relief
	oceanLevel = -0.10, -- elevation below this is ocean (water at sea level)
	mountainLevel = 0.40, -- normalised land-elevation above this is mountains
	coldLevel = -0.22, -- temperature below this is cold (snow)
	hotLevel = 0.22, -- temperature above this is desert (sand)
	plainsAmp = 5, -- flat
	desertAmp = 11, -- gentle dunes
	coldAmp = 15, -- rolling snow
	mountainAmp = 60, -- + ridged detail -> peaks
	snowLine = 50, -- mountains above R+this are snow-capped
	maxRelief = 110, -- worst-case |height - sea level| (streaming band/padding)
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
	color = Color3.fromRGB(135, 182, 255), -- atmosphere haze / limb glow (softens the body silhouette)
}

-- Sky. The world transitions from a bright blue Earth-like sky in the atmosphere to
-- a dark, starry space sky as you climb, blended by altitude (SkyController). The Sun
-- and Moon are Roblox's native celestial bodies (with procedural stars), so they
-- always render no matter how far the craft is from the world origin.
Config.SKY = {
	starCount = 3200,
	sunAngularSize = 24, -- Roblox native Sun disk size
	moonAngularSize = 18, -- Roblox native Moon disk size
	blendStartAlt = 300, -- at/below this altitude the sky is fully atmospheric (blue)
	blendEndAlt = 2700, -- at/above this altitude the sky is fully space (dark + stars)
	dayClockTime = 14, -- atmosphere: midday sun, blue sky
	spaceClockTime = 24, -- space: full night, stars out (true dark sky)
	groundBrightness = 2.6,
	spaceBrightness = 1.7,
	groundAmbient = Color3.fromRGB(80, 84, 96),
	spaceAmbient = Color3.fromRGB(44, 48, 60), -- lights the craft; the dark sky is from ClockTime, not ambient
	groundOutdoor = Color3.fromRGB(150, 152, 160),
	spaceOutdoor = Color3.fromRGB(56, 60, 74),
	atmoDensity = 0.32, -- Atmosphere instance density at sea level
	-- Map view always looks like space (no atmosphere fog) regardless of altitude.
	mapAmbient = Color3.fromRGB(74, 78, 92),
	mapOutdoor = Color3.fromRGB(86, 90, 104),
	mapBrightness = 2.2,
}

-- Map view draws a COMPRESSED copy of the body + orbit (scaled to this render size)
-- near the origin, so it always fits on screen and renders regardless of orbit size.
Config.MAP = {
	frameSize = 8000,
}

-- From-space LOD: the distant planet is a base ocean sphere with a shell of biome-colored
-- land tiles laid over it (sampled from Planet), so you see continents / deserts / ice
-- from orbit. The tiles only show within the planet's render range (in orbit, where they
-- matter); far out it falls back to the plain ocean dot. Higher bands = finer continents
-- but more parts.
Config.LOD = {
	latBands = 18, -- latitude rings of tiles (pole to pole)
	lonBands = 48, -- longitude tiles at the equator (fewer toward the poles)
}

Config.CRAFT = {
	radius = 14,
	riderHeight = 7,
}

Config.LAUNCH = {
	defaultDesign = { "EngineMain", "Fin", "TankL", "TankL", "Pod" }, -- bottom -> top
	-- Launch site direction (unit) from the body centre. On the EQUATOR (X/Z plane) so a
	-- gravity-turn ascent is coplanar with the equatorial Mun -- you can transfer there
	-- with a normal prograde burn, KSP-style.
	site = Vector3.new(1, 0, 0),
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
	thrustTorqueScale = 0.12, -- how hard off-centre engine thrust torques the craft
	maxOmega = 12, -- rad/s angular-velocity safety cap
}
Config.FLOATING_ORIGIN = {
	rebaseThreshold = 1e9, -- the world is small; never rebase (terrain is fixed)
}

Config.INPUT = {
	throttleRate = 0.6,
}

-- Sound asset ids (SoundController). These are placeholders -- swap them for your own
-- uploaded audio for the best result; if an id is invalid the sound simply stays silent
-- (nothing breaks). engine + wind loop; explosion is a one-shot on a crash.
Config.SOUND = {
	engine = "rbxassetid://142376088", -- looped engine rumble
	wind = "rbxassetid://9116367343", -- looped wind
	explosion = "rbxassetid://142070127", -- one-shot explosion
	engineMaxVolume = 0.55,
	windMaxVolume = 0.5,
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
