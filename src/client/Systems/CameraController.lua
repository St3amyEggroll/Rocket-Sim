--[[
	CameraController
	Owner of: the Scriptable camera.

	Two modes (toggle with M, owned by InputController):
	  * Flight (chase): orbit the camera close around the craft + rider.
	  * Map: frame the body and pull back to fit the whole orbit, so you can
	    watch the craft travel around its trajectory (great with time warp).

	Render positions come straight from the sim state + floating origin, so the
	camera stays glued through floating-origin rebases (everything shifts by the
	same delta, so nothing pops).
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
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
	self._mu = Flight:GetMu()
	self._bodyRadius = Flight:GetBodyRadius()

	local cam = Workspace.CurrentCamera
	local waited = 0
	while not cam and waited < 5 do
		waited += task.wait()
		cam = Workspace.CurrentCamera
	end
	self._camera = cam
	if not cam then
		warn("[CameraController] no CurrentCamera; camera disabled")
		return
	end
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
	-- Re-assert in case a (re)spawn handed control back to the default camera.
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local orbit = self._input:GetCameraOrbit()
	local cosE = math.cos(orbit.elevation)
	local dir = Vector3.new(
		math.cos(orbit.azimuth) * cosE,
		math.sin(orbit.elevation),
		math.sin(orbit.azimuth) * cosE
	)

	local target, distance
	if self._input:GetMapMode() then
		-- Frame the body; pull back to fit the orbit.
		target = self._origin:ToRender(Orbit.vec(0, 0, 0))
		local readout = Orbit.getReadout(state, self._mu)
		local p = state.position
		local rNow = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		local apoR = (readout.apoapsis < math.huge) and (readout.apoapsis + self._bodyRadius) or rNow
		local frameR = math.max(apoR, rNow, self._bodyRadius * 1.5)
		distance = frameR * Config.CAMERA.mapFrameMultiplier * orbit.mapZoom
	else
		target = self._origin:ToRender(state.position)
		distance = orbit.distance
	end

	cam.CFrame = CFrame.lookAt(target + dir * distance, target)
end

return CameraController
