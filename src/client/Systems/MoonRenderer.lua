--[[
	MoonRenderer
	Owner of: the always-visible moon body (a mesh sphere) drawn at its Terra-centric
	orbital position.

	Same trick as PlanetRenderer: within maxRender the moon is drawn at true scale and
	position (so you can orbit/land on it seamlessly); beyond it an angular-size proxy
	pulls it into render range so it shrinks to a dot but never culls. Map view draws its
	own moon (MapViewController), so the real one hides there.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local MoonRenderer = {}

local BASE = 2048

function MoonRenderer:Init()
	self._radius = Config.MOON.radius
	self._maxRender = Config.MOON.radius + Config.CAMERA.distanceMax + 4000
end

function MoonRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")
	self._flight = Registry:Get("FlightController")

	local p = Instance.new("Part")
	p.Name = "Moon"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(BASE, BASE, BASE)
	p.Color = Config.MOON.color
	p.Material = Enum.Material.SmoothPlastic
	p.CFrame = CFrame.new(0, 0, 0)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	p.Parent = Workspace
	self._ball = p
	self._mesh = mesh

	RunService:BindToRenderStep("RocketSim_Moon", Enum.RenderPriority.Camera.Value + 2, function()
		self:_update()
	end)
end

function MoonRenderer:_update()
	local cam = Workspace.CurrentCamera
	if not cam or not self._ball then
		return
	end

	-- Map view draws its own compressed moon; hide the real one there.
	if self._input:GetMapMode() then
		if self._ball.Transparency ~= 1 then
			self._ball.Transparency = 1
		end
		return
	elseif self._ball.Transparency ~= 0 then
		self._ball.Transparency = 0
	end

	local center = self._origin:ToRender(self._flight:GetMoonCenter())
	local camPos = cam.CFrame.Position
	local toMoon = center - camPos
	local dist = toMoon.Magnitude

	local renderCenter, scale
	if dist <= self._maxRender or dist < 1e-3 then
		renderCenter, scale = center, 1
	else
		scale = self._maxRender / dist
		renderCenter = camPos + toMoon.Unit * self._maxRender
	end

	local d = self._radius * 2 * scale / BASE
	self._mesh.Scale = Vector3.new(d, d, d)
	self._ball.CFrame = CFrame.new(renderCenter)
end

return MoonRenderer
