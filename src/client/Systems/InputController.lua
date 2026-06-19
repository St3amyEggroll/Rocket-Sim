--[[
	InputController
	Owner of: all player input.

	Flight controls (KSP-style):
	  W / S .......... pitch (nose down / up)
	  A / D .......... yaw (nose left / right)
	  Q / E .......... roll
	  Shift / Ctrl ... throttle up / down (hold)
	  X .............. cut throttle
	  1 2 3 4 5 ...... auto-orient (SAS): Prograde / Retrograde / RadialOut / RadialIn / Ascent
	  Space .......... stage
	  . / , .......... time warp up / down
	  M .............. Map / Flight view
	  B .............. VAB / Flight
	  RMB + drag ..... look around    Wheel ... zoom
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Signal"))
local Registry = require(Shared:WaitForChild("Registry"))

local InputController = {}

function InputController:Init()
	self._throttle = 0
	self._sas = "Ascent" -- Prograde/Retrograde/RadialOut/RadialIn/Ascent/Manual
	self._warpIndex = 1
	self._warpLevels = Config.TIMEWARP.levels
	self._mapMode = Config.CAMERA.startInMapView and true or false
	self._rmbDown = false
	self._cam = {
		azimuth = 0,
		elevation = math.rad(12),
		distance = Config.CAMERA.distanceDefault,
		mapZoom = 1,
	}
	self.StagePressed = Signal.new()
	self.ToggleModePressed = Signal.new()
end

function InputController:Start()
	local camCfg = Config.CAMERA

	Registry:Get("GameModeController").ModeChanged:Connect(function(m)
		if m == "Flight" then
			self._throttle = 0
			self._warpIndex = 1
			self._sas = "Ascent"
			self._cam.azimuth = 0
			self._cam.elevation = math.rad(12)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gp)
		if gp then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local k = input.KeyCode
			if k == Enum.KeyCode.X then
				self._throttle = 0
			elseif k == Enum.KeyCode.One then
				self._sas = "Prograde"
			elseif k == Enum.KeyCode.Two then
				self._sas = "Retrograde"
			elseif k == Enum.KeyCode.Three then
				self._sas = "RadialOut"
			elseif k == Enum.KeyCode.Four then
				self._sas = "RadialIn"
			elseif k == Enum.KeyCode.Five then
				self._sas = "Ascent"
			elseif k == Enum.KeyCode.Period then
				if self._throttle <= 0 then
					self._warpIndex = math.min(#self._warpLevels, self._warpIndex + 1)
				end
			elseif k == Enum.KeyCode.Comma then
				self._warpIndex = math.max(1, self._warpIndex - 1)
			elseif k == Enum.KeyCode.M then
				self._mapMode = not self._mapMode
			elseif k == Enum.KeyCode.Space then
				self.StagePressed:Fire()
			elseif k == Enum.KeyCode.B then
				self.ToggleModePressed:Fire()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			self._rmbDown = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self._rmbDown = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end)

	UserInputService.InputChanged:Connect(function(input, gp)
		if input.UserInputType == Enum.UserInputType.MouseMovement and self._rmbDown then
			self._cam.azimuth = self._cam.azimuth - input.Delta.X * camCfg.orbitSensitivity
			self._cam.elevation = math.clamp(
				self._cam.elevation - input.Delta.Y * camCfg.orbitSensitivity,
				camCfg.minElevation,
				camCfg.maxElevation
			)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not gp then
			local factor = 1 - input.Position.Z * camCfg.zoomSensitivity
			if self._mapMode then
				self._cam.mapZoom = math.clamp(self._cam.mapZoom * factor, camCfg.mapZoomMin, camCfg.mapZoomMax)
			else
				self._cam.distance =
					math.clamp(self._cam.distance * factor, camCfg.distanceMin, camCfg.distanceMax)
			end
		end
	end)

	RunService:BindToRenderStep("RocketSim_Input", Enum.RenderPriority.Input.Value, function(dt)
		local up = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local down = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		local delta = (up and Config.INPUT.throttleRate * dt or 0) - (down and Config.INPUT.throttleRate * dt or 0)
		if delta ~= 0 then
			self._throttle = math.clamp(self._throttle + delta, 0, 1)
		end
		if self._throttle > 0 then
			self._warpIndex = 1
		end
	end)
end

local function keyAxis(neg, pos)
	local v = 0
	if UserInputService:IsKeyDown(pos) then
		v += 1
	end
	if UserInputService:IsKeyDown(neg) then
		v -= 1
	end
	return v
end

-- Manual attitude intent. If any of WASDQE is held, control becomes Manual.
function InputController:GetAttitudeInput()
	local pitch = keyAxis(Enum.KeyCode.S, Enum.KeyCode.W)
	local yaw = keyAxis(Enum.KeyCode.D, Enum.KeyCode.A)
	local roll = keyAxis(Enum.KeyCode.E, Enum.KeyCode.Q)
	if pitch ~= 0 or yaw ~= 0 or roll ~= 0 then
		self._sas = "Manual"
	end
	return pitch, yaw, roll
end

function InputController:GetThrottle()
	return self._throttle
end
function InputController:GetSAS()
	return self._sas
end
function InputController:GetTimeWarp()
	return self._warpLevels[self._warpIndex]
end
function InputController:GetMapMode()
	return self._mapMode
end
function InputController:GetCameraOrbit()
	return self._cam
end
function InputController:GetStageSignal()
	return self.StagePressed
end
function InputController:GetToggleModeSignal()
	return self.ToggleModePressed
end

return InputController
