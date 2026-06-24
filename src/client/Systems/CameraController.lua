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

local function frameFromUp(pos, up)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(pos, pos + fwd.Unit, up)
end

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

-- Altitude (above the active body) at which the camera starts switching from surface
-- (planet-down) to orbital (plane-level). Above the atmosphere for Terra; a low fixed
-- altitude for the airless Mun; ~0 for the Sun (you're always in deep space there).
function CameraController:_orbitCamAlt(bodyId)
	if bodyId == "moon" then
		return Config.CAMERA.orbitCamAltMoon
	elseif bodyId == "sun" then
		return 0
	end
	return Config.ATMOSPHERE.top
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

	-- VAB: orbit the rocket on the pad so you can build it in 3D. Everything is framed in
	-- the launch frame (build +Y -> radial-out) so the craft reads as upright on screen.
	if info and info.mode == "VAB" then
		local base = self._origin:ToRender(self._flight:GetLaunchPosition())
		local up = self._flight:GetLaunchUp()
		local upV = Vector3.new(up.X, up.Y, up.Z)
		local L = frameFromUp(base, upV)
		local h = self._vehicle:GetHeight()
		-- Frame the actual parts (so a free-floating anchor stays in view), not just the pad.
		local target = L:PointToWorldSpace(self._vehicle:GetBuildCenter())
		local cosE = math.cos(orbit.elevation)
		-- Orbit direction in the launch frame, so elevation is measured off the pad's "up".
		local dir = L:VectorToWorldSpace(Vector3.new(
			math.cos(orbit.azimuth) * cosE,
			math.sin(orbit.elevation),
			math.sin(orbit.azimuth) * cosE
		))
		local distance = math.max(orbit.distance, h * 1.1 + 24)
		cam.CFrame = CFrame.lookAt(target + dir * distance, target, upV)
		return
	end

	if self._input:GetMapMode() then
		-- The map schematic is drawn at the LITERAL world origin (MapViewController), so aim
		-- there. (Not ToRender(0): in far mode the floating origin follows the craft, so the
		-- render origin is ~900k out -- the map must stay pinned to a fixed, render-safe spot.)
		local target = Vector3.zero
		local cosE = math.cos(orbit.elevation)
		local dir = Vector3.new(
			math.cos(orbit.azimuth) * cosE,
			math.sin(orbit.elevation),
			math.sin(orbit.azimuth) * cosE
		)
		-- Fixed, render-safe distance: the schematic is always sized to ~frameSize around the
		-- origin (MapView scales the content for zoom), so the camera never has to move out
		-- past the draw range to "zoom out".
		local distance = Config.MAP.frameSize * Config.CAMERA.mapCamMultiplier
		cam.CFrame = CFrame.lookAt(target + dir * distance, target)
		return
	end

	-- Chase camera. Low over a body: gravity-aligned (up = local vertical / radial), so the
	-- planet stays DOWN for launch / re-entry / landing. Out in space: lock to the ORBITAL
	-- plane (up = orbit normal) so the view doesn't slowly rotate as you coast and "up/down"
	-- tilts you above/below the orbit. Blend smoothly across an altitude band.
	local p = state.position
	local r = Vector3.new(p.x, p.y, p.z)
	local radial = (r.Magnitude > 1e-3) and r.Unit or Vector3.yAxis
	local up = radial

	local bodyRadius = (info and info.bodyRadius) or self._bodyRadius or 1
	local alt = r.Magnitude - bodyRadius
	local thr = self:_orbitCamAlt(info and info.bodyId)
	local orbT = math.clamp((alt - thr) / Config.CAMERA.orbitCamBand, 0, 1)
	if orbT > 0 then
		local vo = Vector3.new(state.velocity.x, state.velocity.y, state.velocity.z)
		local nRaw = r:Cross(vo)
		-- Need real transverse velocity for a meaningful plane (a pure vertical hop has none).
		if nRaw.Magnitude > r.Magnitude * vo.Magnitude * 0.15 then
			local n = nRaw.Unit
			if self._lastNormal and n:Dot(self._lastNormal) < 0 then
				n = -n -- keep the same side of the plane frame-to-frame (no sudden flip)
			end
			self._lastNormal = n
			up = radial:Lerp(n, orbT)
			up = (up.Magnitude > 1e-3) and up.Unit or n
		end
	end

	-- Camera heading: the velocity projected onto the local horizon. When flying straight
	-- up/down (ascent/descent) the horizontal part is tiny and its DIRECTION is noise, which
	-- used to spin the view. So only adopt it when there's real horizontal motion; otherwise
	-- keep the previous heading (re-projected onto the current horizon) and ease toward it.
	local function horizOf(vec)
		return vec - up * vec:Dot(up)
	end
	local last = horizOf(self._lastFwd or Vector3.zAxis)
	if last.Magnitude < 1e-3 then
		last = horizOf(Vector3.xAxis)
		if last.Magnitude < 1e-3 then
			last = horizOf(Vector3.zAxis)
		end
	end
	last = last.Unit

	local v = state.velocity
	local v3 = Vector3.new(v.x, v.y, v.z)
	local hv = horizOf(v3)
	local desired = last
	if hv.Magnitude > 6 and hv.Magnitude > v3.Magnitude * 0.12 then
		desired = hv.Unit
	end
	-- Ease toward the desired heading so a gravity turn pans smoothly instead of snapping.
	local fwd = last:Lerp(desired, 0.1)
	fwd = horizOf(fwd)
	fwd = (fwd.Magnitude > 1e-3) and fwd.Unit or desired
	self._lastFwd = fwd

	-- Render at the Terra-centric position (state is relative to the active body).
	local bc = (info and info.bodyCenter) or Orbit.vec(0, 0, 0)
	local craftRender = self._origin:ToRender(Orbit.vec(p.x + bc.x, p.y + bc.y, p.z + bc.z))
	local behind = CFrame.fromAxisAngle(up, orbit.azimuth) * (-fwd)
	local offsetDir = behind * math.cos(orbit.elevation) + up * math.sin(orbit.elevation)
	local camPos = craftRender + offsetDir * orbit.distance
	cam.CFrame = CFrame.lookAt(camPos, craftRender, up)
end

return CameraController
