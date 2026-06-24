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
	local Vehicle = Registry:Get("VehicleController")
	local S = Config.SOUND

	self._engine = self:_makeSound(S.engine, true)
	self._wind = self:_makeSound(S.wind, true)
	self._explosionId = S.explosion
	self._lastStatus = nil
	self._lastSpeed = 0

	if self._engine then
		self._engine:Play()
	end
	if self._wind then
		self._wind:Play()
	end

	-- A clunk each time a stage separates.
	if Vehicle and Vehicle.Staged then
		Vehicle.Staged:Connect(function()
			self:_oneShot(Config.SOUND.staging, Config.SOUND.stagingVolume or 0.6, 0.92 + 0.16 * math.random())
		end)
	end

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

function SoundController:_update(state, info)
	if not info then
		return
	end

	-- Engine: louder + higher-pitched with actual thrust (thrustLevel stays high for a firing
	-- solid even at zero throttle). Eased so it doesn't click on throttle/stage changes.
	if self._engine then
		local thr = info.thrustLevel or 0
		local volT = (Config.SOUND.engineMaxVolume or 0.6) * thr
		local pitchT = 0.7 + 0.65 * thr
		self._engine.Volume += (volT - self._engine.Volume) * 0.2
		self._engine.PlaybackSpeed += (pitchT - self._engine.PlaybackSpeed) * 0.2
	end

	-- Air state (for wind + sonic boom): density * speed in Terra's atmosphere.
	local rho, speed = 0, 0
	if info.bodyId == "planet" then
		local p = state.position
		local alt = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - (info.bodyRadius or 0)
		if alt < Config.ATMOSPHERE.top then
			rho = math.exp(-math.max(alt, 0) / Config.ATMOSPHERE.scaleHeight)
		end
		local v = state.velocity
		speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	end

	-- Wind roar keyed to DYNAMIC PRESSURE (rho * speed^2), so it swells toward max-Q on the
	-- way up and dies off as the air thins -- the classic ascent roar.
	if self._wind then
		local q = rho * speed * speed
		local volT = math.clamp(q / 90000, 0, Config.SOUND.windMaxVolume or 0.55)
		self._wind.Volume += (volT - self._wind.Volume) * 0.15
		self._wind.PlaybackSpeed = 0.85 + math.clamp(q / 200000, 0, 0.5)
	end

	-- Sonic boom: a one-shot as the craft accelerates up through the sound barrier in air
	-- thick enough to carry it.
	local mach = Config.SOUND.machSpeed or 330
	if rho > 0.18 and self._lastSpeed < mach and speed >= mach then
		self:_oneShot(Config.SOUND.sonicBoom, Config.SOUND.sonicBoomVolume or 0.8, 1)
	end
	self._lastSpeed = speed

	-- Explosion: one-shot on the transition into a crash.
	if info.status == "Crashed" and self._lastStatus ~= "Crashed" then
		self:_oneShot(self._explosionId, 1, 1)
	end
	self._lastStatus = info.status
end

-- Fire-and-forget one-shot sound (cleaned up after it plays). Silent if the id is empty.
function SoundController:_oneShot(id, volume, speed)
	if not id or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 1
	s.PlaybackSpeed = speed or 1
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 6)
end

return SoundController
