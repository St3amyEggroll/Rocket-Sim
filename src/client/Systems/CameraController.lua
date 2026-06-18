--[[
	CameraController
	Owner of: the Scriptable camera.

	Orbits the camera around the craft's render position using the orbit state
	owned by InputController. It derives the craft's render position straight from
	the sim state + floating origin, so it is independent of render ordering and
	stays glued to the craft through floating-origin rebases (the camera target
	and every rendered object shift by the same delta, so nothing pops).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CameraController = {}

function CameraController:Init()
	self._camera = nil
end

function CameraController:Start()
	self._input = Registry:Get("InputController")
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")

	local cam = Workspace.CurrentCamera
	while not cam do
		task.wait()
		cam = Workspace.CurrentCamera
	end
	self._camera = cam
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Config.CAMERA.fieldOfView

	self:_update(Flight:GetState())
	Flight:GetUpdatedSignal():Connect(function(state)
		self:_update(state)
	end)
end

function CameraController:_update(state)
	local cam = self._camera
	if not cam then
		return
	end

	local orbit = self._input:GetCameraOrbit()
	local target = self._origin:ToRender(state.position)

	local cosE = math.cos(orbit.elevation)
	local dir = Vector3.new(
		math.cos(orbit.azimuth) * cosE,
		math.sin(orbit.elevation),
		math.sin(orbit.azimuth) * cosE
	)

	local camPos = target + dir * orbit.distance
	cam.CFrame = CFrame.lookAt(camPos, target)
end

return CameraController
