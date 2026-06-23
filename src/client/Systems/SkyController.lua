--[[
	SkyController
	Owner of: the sky environment -- the Sun, Moon, stars, and the blend between an
	Earth-like blue sky in the atmosphere and a dark, starry space sky.

	The Sun and Moon are Roblox's NATIVE celestial bodies (with procedural stars), so
	they always render regardless of how far the craft has flown from the world origin
	(custom far-away sphere parts would be distance-culled at this planet's scale).

	The look is keyed to the craft's altitude (Config.SKY.blendStart/EndAlt): as you
	climb, ClockTime rolls from midday toward night (the sky darkens and stars appear),
	the Atmosphere thins from a blue haze to clear, and ambient light cools. Coming
	back down reverses it -- a smooth space <-> atmosphere transition.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local SkyController = {}

function SkyController:Init()
	self._alt = 0
	self._mapMode = false
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
	end)

	RunService:BindToRenderStep("RocketSim_Sky", Enum.RenderPriority.Camera.Value + 3, function()
		self:_update()
	end)
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
	Lighting.Brightness = SKY.groundBrightness + (SKY.spaceBrightness - SKY.groundBrightness) * t
	Lighting.Ambient = SKY.groundAmbient:Lerp(SKY.spaceAmbient, t)
	Lighting.OutdoorAmbient = SKY.groundOutdoor:Lerp(SKY.spaceOutdoor, t)

	if self._atmo then
		self._atmo.Density = SKY.atmoDensity * (1 - t)
		self._atmo.Haze = 0.6 * (1 - t)
		self._atmo.Glare = 0
	end
end

return SkyController
