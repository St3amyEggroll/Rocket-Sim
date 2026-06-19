--[[
	InputController
	Owner of: all player input state (throttle, thrust mode, time warp, camera
	orbit, and the map/flight view toggle).

	Other systems read this state at runtime; nobody else touches input.

	Controls:
	  Shift / Ctrl ... throttle up / down (hold)
	  Z / X .......... throttle full / cut
	  1 2 3 4 ........ thrust: Prograde / Retrograde / RadialOut / RadialIn
	  . / , .......... time warp up / down (engine off only)
	  M .............. toggle Map view / Flight (chase) view
	  RMB + drag ..... orbit the camera
	  Mouse wheel .... zoom
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
	self._thrustMode = "Ascent"
	self._warpIndex = 1
	self._warpLevels = Config.TIMEWARP.levels
	self._mapMode = Config.CAMERA.startInMapView and true or false
	self._rmbDown = false
	self._cam = {
		azimuth = Config.CAMERA.defaultAzimuth,
		elevation = Config.CAMERA.defaultElevation,
		distance = Config.CAMERA.distanceDefault,
		mapZoom = 1,
	}
	-- Discrete action events (created in Init so others can connect in Start).
	self.StagePressed = Signal.new()
	self.ToggleModePressed = Signal.new()
end

function InputController:Start()
	local inputCfg = Config.INPUT
	local camCfg = Config.CAMERA

	-- On launch, reset to a clean ascent: no throttle, no warp, autopilot mode.
	Registry:Get("GameModeController").ModeChanged:Connect(function(m)
		if m == "Flight" then
			self._throttle = 0
			self._warpIndex = 1
			self._thrustMode = "Ascent"
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local k = input.KeyCode
			if k == Enum.KeyCode.Z then
				self._throttle = 1
				self._warpIndex = 1
			elseif k == Enum.KeyCode.X then
				self._throttle = 0
			elseif k == Enum.KeyCode.One then
				self._thrustMode = "Prograde"
			elseif k == Enum.KeyCode.Two then
				self._thrustMode = "Retrograde"
			elseif k == Enum.KeyCode.Three then
				self._thrustMode = "RadialOut"
			elseif k == Enum.KeyCode.Four then
				self._thrustMode = "RadialIn"
			elseif k == Enum.KeyCode.Five then
				self._thrustMode = "Ascent"
			elseif k == Enum.KeyCode.Period then
				-- Warp up only while coasting.
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

	UserInputService.InputChanged:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if self._rmbDown then
				self._cam.azimuth = self._cam.azimuth - input.Delta.X * camCfg.orbitSensitivity
				self._cam.elevation = math.clamp(
					self._cam.elevation - input.Delta.Y * camCfg.orbitSensitivity,
					camCfg.minElevation,
					camCfg.maxElevation
				)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not gameProcessed then
			local factor = 1 - input.Position.Z * camCfg.zoomSensitivity
			if self._mapMode then
				self._cam.mapZoom = math.clamp(self._cam.mapZoom * factor, camCfg.mapZoomMin, camCfg.mapZoomMax)
			else
				self._cam.distance =
					math.clamp(self._cam.distance * factor, camCfg.distanceMin, camCfg.distanceMax)
			end
		end
	end)

	-- Continuous throttle ramp from held Shift / Ctrl.
	RunService:BindToRenderStep("RocketSim_Input", Enum.RenderPriority.Input.Value, function(dt)
		local up = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local down = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)

		local delta = 0
		if up then
			delta += inputCfg.throttleRate * dt
		end
		if down then
			delta -= inputCfg.throttleRate * dt
		end
		if delta ~= 0 then
			self._throttle = math.clamp(self._throttle + delta, 0, 1)
		end

		-- No warp while the engine is firing.
		if self._throttle > 0 then
			self._warpIndex = 1
		end
	end)
end

function InputController:GetThrottle(): number
	return self._throttle
end

function InputController:GetThrustMode(): string
	return self._thrustMode
end

function InputController:GetTimeWarp(): number
	return self._warpLevels[self._warpIndex]
end

function InputController:GetMapMode(): boolean
	return self._mapMode
end

-- Live camera orbit table { azimuth, elevation, distance, mapZoom }.
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
