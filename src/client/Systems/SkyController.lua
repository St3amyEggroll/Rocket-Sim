--[[
	SkyController
	Owner of: the sky environment -- the starfield and the blend between an Earth-like blue
	sky in the atmosphere and a dark, starry space sky.

	The native Sun/Moon DISCS are hidden (Config.SKY.*AngularSize = 0); the real Sun is its
	own world body (SunRenderer) and the Mun is MoonRenderer. Roblox's procedural stars stay.

	The look is keyed to the craft's altitude (Config.SKY.blendStart/EndAlt): as you climb,
	ClockTime rolls to night early (sky darkens, stars appear), the Atmosphere thins to clear,
	and ambient cools. In space the lighting is also keyed to whether the Sun reaches the
	craft -- it darkens toward black in Terra's or the Mun's shadow (orbital night / eclipses).
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local SkyController = {}

local function smoothstep(e0, e1, x)
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- How deep `craft` is in body B's shadow (B at centerB, radius radiusB), for sunlight coming
-- from `sunDir` (unit, pointing toward the Sun). 1 = fully eclipsed, 0 = lit. A cylindrical
-- shadow approximation (good enough at these distances) with a soft penumbra edge.
local function shadowOf(craft, centerB, radiusB, sunDir)
	local d = craft - centerB
	local along = -d:Dot(sunDir) -- distance along the anti-sun (shadow) axis
	if along <= 0 then
		return 0 -- craft is on the sunlit side of B
	end
	local perp = (d + sunDir * along).Magnitude -- distance from the shadow axis
	return 1 - smoothstep(radiusB * 0.8, radiusB * 1.2, perp)
end

function SkyController:Init()
	self._alt = 0
	self._mapMode = false
	self._sunlit = 1 -- 1 = in sunlight, 0 = fully in shadow / eclipse
	self._bodyRadius = Config.BODY.radius
end

function SkyController:Start()
	local Flight = Registry:Get("FlightController")
	self:_setupSky()

	Flight:GetUpdatedSignal():Connect(function(state, info)
		if info and info.bodyId == "moon" then
			-- Airless moon: always the space sky (stars), regardless of moon altitude.
			self._alt = Config.SKY.blendEndAlt
		else
			local p = state.position
			self._alt = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - self._bodyRadius
		end
		self._mapMode = info and info.mapMode or false
		self._sunlit = self:_computeSunlit(state, info)
	end)

	RunService:BindToRenderStep("RocketSim_Sky", Enum.RenderPriority.Camera.Value + 3, function()
		self:_update()
	end)
end

-- Fraction of sunlight reaching the craft: 1 in the open, dropping to ~0 when Terra or the
-- Mun is between the craft and the Sun (orbital night, and eclipses when the Mun crosses).
function SkyController:_computeSunlit(state, info)
	if not (info and info.sunDir) then
		return 1
	end
	local sunDir = info.sunDir
	if sunDir.Magnitude < 1e-3 then
		return 1
	end
	sunDir = sunDir.Unit
	local bc = info.bodyCenter or { x = 0, y = 0, z = 0 }
	local craft = Vector3.new(state.position.x + bc.x, state.position.y + bc.y, state.position.z + bc.z)

	local shadow = shadowOf(craft, Vector3.zero, Config.BODY.radius, sunDir) -- Terra
	if info.moonCenter then
		local mc = Vector3.new(info.moonCenter.x, info.moonCenter.y, info.moonCenter.z)
		shadow = math.max(shadow, shadowOf(craft, mc, Config.MOON.radius, sunDir)) -- the Mun
	end
	return 1 - shadow
end

function SkyController:_setupSky()
	Lighting.GeographicLatitude = 20
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.35
	Lighting.FogEnd = 1e9

	local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky")
	sky.StarCount = Config.SKY.starCount
	sky.CelestialBodiesShown = true -- Roblox's Sun + Moon + stars
	sky.SunAngularSize = Config.SKY.sunAngularSize
	sky.MoonAngularSize = Config.SKY.moonAngularSize
	sky.Parent = Lighting

	local atmo = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmo.Color = Color3.fromRGB(199, 209, 255)
	atmo.Decay = Color3.fromRGB(92, 120, 180)
	-- No glare and only light haze: the glare put a bright band on the horizon toward the
	-- sun, which read as a "light/dark line down the middle" during the climb.
	atmo.Glare = 0
	atmo.Haze = 0.6
	atmo.Density = Config.SKY.atmoDensity
	atmo.Parent = Lighting
	self._atmo = atmo
end

function SkyController:_update()
	local SKY = Config.SKY

	-- Map view is always space: a dark, star-lit sky with NO atmosphere fog, whatever
	-- the craft's altitude, so the orbit reads clearly.
	if self._mapMode then
		Lighting.ClockTime = SKY.spaceClockTime
		Lighting.Brightness = SKY.mapBrightness
		Lighting.Ambient = SKY.mapAmbient
		Lighting.OutdoorAmbient = SKY.mapOutdoor
		if self._atmo then
			self._atmo.Density = 0
			self._atmo.Haze = 0
			self._atmo.Glare = 0
		end
		return
	end

	-- Atmosphere (blue, day) -> Space (dark, stars).
	local t = math.clamp((self._alt - SKY.blendStartAlt) / (SKY.blendEndAlt - SKY.blendStartAlt), 0, 1)
	-- Reach FULL night early in the climb (by ~40% of the blend) and hold it, so the whole
	-- upper ascent is uniformly dark instead of sitting in a banded dusk "right before space".
	-- The brief dusk only happens low down, where thick atmosphere washes it out.
	local tNight = math.clamp(t / 0.4, 0, 1)
	Lighting.ClockTime = SKY.dayClockTime + (SKY.spaceClockTime - SKY.dayClockTime) * tNight

	-- Eclipse / orbital night: in space (no atmospheric scattering) the craft is lit only when
	-- the Sun reaches it, so darken the space end toward black as it enters Terra's or the
	-- Mun's shadow. On the ground (t~0) this has no effect -- daylight is ClockTime-driven.
	local sunlit = self._sunlit or 1
	local dark = Color3.fromRGB(16, 18, 26) -- not pure black, so the craft stays faintly visible
	local spaceAmb = SKY.spaceAmbient:Lerp(dark, 1 - sunlit)
	local spaceOut = SKY.spaceOutdoor:Lerp(dark, 1 - sunlit)
	local spaceBright = SKY.spaceBrightness * (0.35 + 0.65 * sunlit)

	Lighting.Brightness = SKY.groundBrightness + (spaceBright - SKY.groundBrightness) * t
	Lighting.Ambient = SKY.groundAmbient:Lerp(spaceAmb, t)
	Lighting.OutdoorAmbient = SKY.groundOutdoor:Lerp(spaceOut, t)

	if self._atmo then
		self._atmo.Density = SKY.atmoDensity * (1 - t)
		self._atmo.Haze = 0.6 * (1 - t)
		self._atmo.Glare = 0
	end
end

return SkyController
