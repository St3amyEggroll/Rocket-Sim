--[[
	SunRenderer
	Owner of: the always-visible Sun (the root body) drawn at its Terra-centric position
	(-Terra(t)). Terra orbits the Sun, so in the Terra-centric render frame the Sun sweeps
	slowly around the sky.

	Same angular-size trick as PlanetRenderer / MoonRenderer: the Sun is very far away, so it
	is pulled into render range along the line of sight and scaled by the same factor -- its
	on-screen size and direction are preserved exactly, it never distance-culls. The body is
	Neon (self-lit, full-bright) with a translucent ForceField corona for a soft glow.

	The native skybox Sun is hidden (Config.SKY.sunAngularSize = 0); THIS is the real sun.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local RenderScale = require(Shared:WaitForChild("RenderScale"))

local SunRenderer = {}

local BASE = 2048

function SunRenderer:Init()
	self._radius = Config.SUN.radius
	-- Pull-in distance comes from the shared RenderScale (Config.RENDER) so the Sun, always
	-- far, compresses to ~maxDist and renders BEHIND Terra/the Mun rather than through them.
end

function SunRenderer:_makeSphere(name, color, material, transparency)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(BASE, BASE, BASE)
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.CFrame = CFrame.new(0, 0, 0)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	p.Parent = Workspace
	return p, mesh
end

function SunRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._input = Registry:Get("InputController")
	self._flight = Registry:Get("FlightController")

	self._ball, self._mesh = self:_makeSphere("Sun", Config.SUN.color, Enum.Material.Neon, 0)
	-- A soft corona: a larger, translucent ForceField shell (brightest at the limb).
	self._corona, self._coronaMesh =
		self:_makeSphere("SunCorona", Config.SUN.color:Lerp(Color3.new(1, 1, 1), 0.2), Enum.Material.ForceField, 0.72)

	RunService:BindToRenderStep("RocketSim_Sun", Enum.RenderPriority.Camera.Value + 2, function()
		self:_update()
	end)
end

function SunRenderer:_apply(mesh, part, diameter, center)
	local sc = diameter / BASE
	mesh.Scale = Vector3.new(sc, sc, sc)
	part.CFrame = CFrame.new(center)
end

function SunRenderer:_update()
	local cam = Workspace.CurrentCamera
	if not cam or not self._ball then
		return
	end

	-- Map view draws its own compressed Sun (MapViewController); hide the real one there.
	if self._input:GetMapMode() then
		if self._ball.Transparency ~= 1 then
			self._ball.Transparency = 1
			self._corona.Transparency = 1
		end
		return
	elseif self._ball.Transparency ~= 0 then
		self._ball.Transparency = 0
		self._corona.Transparency = 0.72
	end

	local center = self._origin:ToRender(self._flight:GetSunCenter())
	local camPos = cam.CFrame.Position
	local toSun = center - camPos
	local dist = toSun.Magnitude

	-- Depth-correct pull-in (shared with Planet/Moon): the Sun is always far, so it compresses
	-- to nearly maxDist and therefore renders BEHIND Terra/the Mun instead of through them.
	local rd, scale = RenderScale.pull(dist, Config.RENDER.nearDist, Config.RENDER.maxDist)
	local renderCenter = (dist < 1e-3) and center or (camPos + toSun.Unit * rd)

	self:_apply(self._mesh, self._ball, self._radius * 2 * scale, renderCenter)
	self:_apply(self._coronaMesh, self._corona, self._radius * 2.4 * scale, renderCenter)
end

return SunRenderer
