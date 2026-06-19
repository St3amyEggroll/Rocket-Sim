--[[
	CameraController
	Owner of: the Scriptable camera.

	Flight (chase): sits behind the craft's nose (its current attitude) and looks
	forward, so manual WASD steering is intuitive. RMB orbits the view; wheel zooms.
	Map: frames the (compressed) body + orbit at a fixed, render-safe distance.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CameraController = {}

function CameraController:Init() end

function CameraController:Start()
	self._input = Registry:Get("InputController")
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")

	local cam = Workspace.CurrentCamera
	local waited = 0
	while not cam and waited < 5 do
		waited += task.wait()
		cam = Workspace.CurrentCamera
	end
	self._camera = cam
	if cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = Config.CAMERA.fieldOfView
	end

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

function CameraController:_update(state, info)
	local cam = self._camera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local orbit = self._input:GetCameraOrbit()

	if self._input:GetMapMode() then
		local target = self._origin:ToRender(Orbit.vec(0, 0, 0))
		local cosE = math.cos(orbit.elevation)
		local dir = Vector3.new(
			math.cos(orbit.azimuth) * cosE,
			math.sin(orbit.elevation),
			math.sin(orbit.azimuth) * cosE
		)
		local distance = Config.RENDER.mapViewRadius * Config.RENDER.mapCamMultiplier * orbit.mapZoom
		cam.CFrame = CFrame.lookAt(target + dir * distance, target)
		return
	end

	local att = info and info.attitude or CFrame.lookAt(Vector3.zero, Vector3.xAxis, Vector3.yAxis)
	local nose = att.LookVector
	local up = att.UpVector
	local craftRender = self._origin:ToRender(state.position)

	local behind = -nose
	local offsetDir = behind * math.cos(orbit.elevation) + up * math.sin(orbit.elevation)
	offsetDir = CFrame.fromAxisAngle(up, orbit.azimuth) * offsetDir

	local camPos = craftRender + offsetDir * orbit.distance + up * (orbit.distance * 0.12)
	cam.CFrame = CFrame.lookAt(camPos, craftRender + nose * (orbit.distance * 0.15))
end

return CameraController
