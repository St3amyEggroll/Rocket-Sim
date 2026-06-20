--[[
	PlanetRenderer
	Owner of: the always-visible planet body (the low-detail LOD).

	Roblox will not draw even a 2000-stud anchored part once it is past the camera's
	far render range, so a planet fixed at the world origin vanishes when you fly far
	out. To guarantee the body is ALWAYS on screen we draw it as a distance-clamped
	proxy: if the true planet centre is farther than maxRender from the camera, we
	pull the sphere in to maxRender along the same line of sight and scale it by the
	same factor. Angular size and screen direction are preserved exactly, so it looks
	identical to the real body and shrinks to a dot as you leave - it just never
	exits the render range. Within maxRender the sphere sits at its true position and
	radius, so the streamed terrain (TerrainController) lines up on top of it.

	This is purely how the body is DRAWN for the camera; what terrain loads is keyed
	to the craft, not the camera (see TerrainController).
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local PlanetRenderer = {}

function PlanetRenderer:Init()
	self._trueRadius = Planet.lodRadius()
	-- Comfortably inside Roblox's render range, and beyond the camera's max zoom
	-- so the planet always sorts behind the (nearby) craft.
	self._maxRender = math.max(12000, Config.CAMERA.distanceMax * 1.3)
	self._lastDist = -1
end

function PlanetRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")

	local lod = self._trueRadius
	local ball = Instance.new("Part")
	ball.Name = "Planet"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(lod * 2, lod * 2, lod * 2)
	ball.Anchored = true
	ball.CanCollide = false -- visual LOD only; the streamed terrain + pad are the ground
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Color = Config.BODY.grassColor
	ball.Material = Enum.Material.Grass
	ball.CFrame = CFrame.new(0, 0, 0)
	ball.Parent = Workspace
	self._ball = ball

	-- Update after the camera has been positioned for this frame.
	RunService:BindToRenderStep("RocketSim_Planet", Enum.RenderPriority.Camera.Value + 2, function()
		self:_update()
	end)
end

function PlanetRenderer:_update()
	local cam = Workspace.CurrentCamera
	local ball = self._ball
	if not cam or not ball then
		return
	end

	local center = self._origin:ToRender(Orbit.vec(0, 0, 0))
	local camPos = cam.CFrame.Position
	local toPlanet = center - camPos
	local dist = toPlanet.Magnitude

	if dist <= self._maxRender or dist < 1e-3 then
		-- Close enough to draw at true scale; terrain aligns with it.
		if self._lastDist ~= 0 then
			ball.Size = Vector3.new(self._trueRadius * 2, self._trueRadius * 2, self._trueRadius * 2)
			self._lastDist = 0
		end
		ball.CFrame = CFrame.new(center)
	else
		-- Pull the far planet into render range, preserving its angular size.
		local scale = self._maxRender / dist
		local r = self._trueRadius * scale
		ball.Size = Vector3.new(r * 2, r * 2, r * 2)
		ball.CFrame = CFrame.new(camPos + toPlanet.Unit * self._maxRender)
		self._lastDist = dist
	end
end

return PlanetRenderer
