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
	local p = state.position

	if self._input:GetMapMode() then
		-- Map: the world is compressed into a fixed radius around the body, so a
		-- fixed, render-safe camera distance always frames it.
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

	-- Chase: orbit the camera in the craft's LOCAL frame (up = away from planet)
	-- so the planet stays below / on screen as the craft goes around.
	local craftRender = self._origin:ToRender(p)
	local up = Vector3.new(p.x, p.y, p.z)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis

	local v = state.velocity
	local fwd = Vector3.new(v.x, v.y, v.z)
	fwd = fwd - up * fwd:Dot(up)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
		if fwd.Magnitude < 1e-3 then
			fwd = up:Cross(Vector3.zAxis)
		end
	end
	fwd = fwd.Unit
	local right = up:Cross(fwd)

	local az, el = orbit.azimuth, orbit.elevation
	local horiz = (-fwd) * math.cos(az) + right * math.sin(az)
	local offsetDir = horiz * math.cos(el) + up * math.sin(el)
	cam.CFrame = CFrame.lookAt(craftRender + offsetDir * orbit.distance, craftRender)
end

return CameraController
