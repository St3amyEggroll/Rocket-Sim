--[[
	SoundController
	Owner of: flight audio -- a looping engine roar (pitch/volume by throttle), looping
	wind (by air density * speed in the atmosphere), and a one-shot explosion on a crash.

	Sound ids come from Config.SOUND (placeholders -- swap for your own). If an id is
	invalid the Sound just stays silent, so nothing breaks.
]]

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local SoundController = {}

function SoundController:Init() end

function SoundController:_makeSound(id, looped)
	if not id or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = looped or false
	s.Volume = 0
	s.Parent = SoundService
	return s
end

function SoundController:Start()
	local Flight = Registry:Get("FlightController")
	local S = Config.SOUND

	self._engine = self:_makeSound(S.engine, true)
	self._wind = self:_makeSound(S.wind, true)
	self._explosionId = S.explosion
	self._lastStatus = nil

	if self._engine then
		self._engine:Play()
	end
	if self._wind then
		self._wind:Play()
	end

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

function SoundController:_update(state, info)
	if not info then
		return
	end

	-- Engine: louder + higher-pitched with throttle while burning.
	if self._engine then
		local thr = (info.powered and info.throttle) or 0
		self._engine.Volume = (Config.SOUND.engineMaxVolume or 0.55) * thr
		self._engine.PlaybackSpeed = 0.75 + 0.5 * thr
	end

	-- Wind: dynamic-pressure-ish (air density * speed) inside Terra's atmosphere.
	if self._wind then
		local vol = 0
		if info.inAtmo and info.bodyId == "planet" then
			local p = state.position
			local alt = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - (info.bodyRadius or 0)
			local rho = math.exp(-math.max(alt, 0) / Config.ATMOSPHERE.scaleHeight)
			local v = state.velocity
			local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
			vol = math.clamp(rho * speed / 240, 0, Config.SOUND.windMaxVolume or 0.5)
		end
		self._wind.Volume = vol
	end

	-- Explosion: one-shot on the transition into a crash.
	if info.status == "Crashed" and self._lastStatus ~= "Crashed" then
		self:_playExplosion()
	end
	self._lastStatus = info.status
end

function SoundController:_playExplosion()
	if not self._explosionId or self._explosionId == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = self._explosionId
	s.Volume = 1
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 5)
end

return SoundController
