--[[
	InputController
	Owner of: all player input state (throttle, thrust mode, camera orbit).

	Other systems read this state at runtime; nobody else touches input. Throttle
	ramps on a render-step bound at Input priority so it is always up to date
	before FlightController reads it later in the same frame.

	Controls:
	  Shift / Ctrl ... throttle up / down (hold)
	  Z / X .......... throttle full / cut
	  1 2 3 4 ........ thrust direction: Prograde / Retrograde / RadialOut / RadialIn
	  RMB + drag ..... orbit the camera
	  Mouse wheel .... zoom
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))

local InputController = {}

function InputController:Init()
	self._throttle = 0
	self._thrustMode = "Prograde"
	self._rmbDown = false
	self._cam = {
		azimuth = math.rad(35),
		elevation = math.rad(18),
		distance = Config.CAMERA.distanceDefault,
	}
end

function InputController:Start()
	local inputCfg = Config.INPUT
	local camCfg = Config.CAMERA

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local k = input.KeyCode
			if k == Enum.KeyCode.Z then
				self._throttle = 1
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
			self._cam.distance =
				math.clamp(self._cam.distance * factor, camCfg.distanceMin, camCfg.distanceMax)
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
	end)
end

function InputController:GetThrottle(): number
	return self._throttle
end

function InputController:GetThrustMode(): string
	return self._thrustMode
end

-- Returns the live camera orbit table { azimuth, elevation, distance }.
function InputController:GetCameraOrbit()
	return self._cam
end

return InputController
