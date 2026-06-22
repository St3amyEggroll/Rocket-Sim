--[[
	CameraController
	Owner of: the Scriptable camera.

	Flight: a KSP-style gravity/orbit-aligned camera. The camera's UP is the local
	vertical (radial), so the horizon stays level and the planet stays DOWN and on
	screen at any altitude. It trails the craft's horizontal velocity, which lies
	in the orbital plane, so the view is naturally coplanar with the orbit. The
	craft rotates freely within the view (read attitude off the navball). RMB
	orbits, wheel zooms.

	Map: frames the compressed body + orbit at a fixed, render-safe distance.
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
	self._vehicle = Registry:Get("VehicleController")
	self._flight = Registry:Get("FlightController")
	local Flight = self._flight
	self._bodyRadius = Flight:GetBodyRadius()

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

	self._lastFwd = Vector3.zAxis

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

	-- VAB: orbit the rocket on the pad so you can build it in 3D.
	if info and info.mode == "VAB" then
		local base = self._origin:ToRender(self._flight:GetLaunchPosition())
		local h = self._vehicle:GetHeight()
		local target = base + Vector3.new(0, math.max(h * 0.5, 6), 0)
		local cosE = math.cos(orbit.elevation)
		local dir = Vector3.new(
			math.cos(orbit.azimuth) * cosE,
			math.sin(orbit.elevation),
			math.sin(orbit.azimuth) * cosE
		)
		local distance = math.max(orbit.distance, h * 1.1 + 24)
		cam.CFrame = CFrame.lookAt(target + dir * distance, target)
		return
	end

	if self._input:GetMapMode() then
		local target = self._origin:ToRender(Orbit.vec(0, 0, 0))
		local cosE = math.cos(orbit.elevation)
		local dir = Vector3.new(
			math.cos(orbit.azimuth) * cosE,
			math.sin(orbit.elevation),
			math.sin(orbit.azimuth) * cosE
		)
		local R = self._bodyRadius or 500
		local frameR = (info and info.mapFrameRadius) or R * 2
		frameR = math.max(frameR, R * 1.4)
		local distance = frameR * Config.CAMERA.mapCamMultiplier * orbit.mapZoom
		cam.CFrame = CFrame.lookAt(target + dir * distance, target)
		return
	end

	-- Gravity-aligned chase: up = local vertical (radial).
	local p = state.position
	local up = Vector3.new(p.x, p.y, p.z)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis

	-- Horizontal forward = velocity projected onto the local horizon (lies in the
	-- orbital plane). Fall back to the nose, then to the last good forward.
	local function horiz(v)
		local h = v - up * v:Dot(up)
		return (h.Magnitude > 1e-3) and h.Unit or nil
	end
	local v = state.velocity
	local fwd = horiz(Vector3.new(v.x, v.y, v.z))
	if not fwd then
		local nose = info and info.attitude and info.attitude.LookVector
		fwd = (nose and horiz(nose)) or self._lastFwd
	end
	self._lastFwd = fwd

	local craftRender = self._origin:ToRender(p)
	local behind = CFrame.fromAxisAngle(up, orbit.azimuth) * (-fwd)
	local offsetDir = behind * math.cos(orbit.elevation) + up * math.sin(orbit.elevation)
	local camPos = craftRender + offsetDir * orbit.distance
	cam.CFrame = CFrame.lookAt(camPos, craftRender, up)
end

return CameraController
