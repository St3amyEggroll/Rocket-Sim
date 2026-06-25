--[[
	LaunchSiteController
	Owner of: the launch PAD -- a raised concrete platform with a dark launch mount + hold-down
	clamps that the rocket stands on.

	It lives at the fixed equatorial launch site, oriented radial-out, with the pad deck
	Config.LAUNCH.padHeight studs above the terrain (the craft's base sits on it). It is shown
	only while the craft is near Terra's surface (like the streamed terrain) -- hidden in space,
	in map view, and behind the menu cinematic. The pad is one Model, re-pivoted each frame
	through the floating origin so it stays put as the world rebases.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local LaunchSiteController = {}

local CONCRETE = Color3.fromRGB(98, 100, 106)
local DARKCON = Color3.fromRGB(62, 64, 72)
local STEEL = Color3.fromRGB(124, 128, 136)
local METALDARK = Color3.fromRGB(48, 50, 58)

-- A CFrame at `pos` whose UP axis is `up` (matches the craft / pad orientation).
local function frameFromUp(pos, up)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(pos, pos + fwd.Unit, up)
end

local function box(parent, size, color, material, cf)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = cf
	p.Parent = parent
	return p
end

function LaunchSiteController:Init()
	self._visible = false
end

function LaunchSiteController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")

	local up = Flight:GetLaunchUp()
	self._up = Vector3.new(up.X, up.Y, up.Z)
	self._groundR = Planet.radiusForUnit(up.X, up.Y, up.Z) -- terrain surface at the site
	self._siteSim = Orbit.vec(up.X * self._groundR, up.Y * self._groundR, up.Z * self._groundR)

	self:_build()

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

-- Build the whole site as one Model in LOCAL space: origin = the ground point, +Y = up
-- (radial). The model's pivot (an invisible root at the local origin) is moved to the world
-- launch frame each frame; everything else rides along rigidly.
function LaunchSiteController:_build()
	local padH = Config.LAUNCH.padHeight or 10
	local model = Instance.new("Model")
	model.Name = "LaunchSite"

	local root = box(model, Vector3.new(0.4, 0.4, 0.4), CONCRETE, Enum.Material.SmoothPlastic, CFrame.new())
	root.Transparency = 1
	model.PrimaryPart = root

	local function at(x, y, z)
		return CFrame.new(x, y, z)
	end

	-- ---- Launch pad: a raised concrete platform whose deck top sits at y = padH ----
	local slabH = padH + 8
	box(model, Vector3.new(76, slabH, 76), CONCRETE, Enum.Material.Concrete, at(0, padH - slabH / 2, 0))
	-- corner support pylons sunk into the ground.
	for _, sx in ipairs({ -32, 32 }) do
		for _, sz in ipairs({ -32, 32 }) do
			box(model, Vector3.new(8, padH + 12, 8), DARKCON, Enum.Material.Concrete, at(sx, padH - (padH + 12) / 2, sz))
		end
	end
	-- A flush metal deck plate: its top sits exactly at the deck height (= the craft's base),
	-- so the rocket stands ON it -- no raised mount or recessed hole for it to sink into.
	box(model, Vector3.new(34, 2, 34), METALDARK, Enum.Material.DiamondPlate, at(0, padH - 1, 0))
	-- hold-down clamps standing beside the rocket base.
	for i = 0, 3 do
		local a = i * math.pi / 2
		box(model, Vector3.new(2.4, 6, 2.4), STEEL, Enum.Material.Metal, at(math.cos(a) * 11, padH + 3, math.sin(a) * 11))
	end

	self._model = model
end

function LaunchSiteController:_update(state, info)
	if not self._model then
		return
	end

	-- Show only near Terra's surface, in normal flight/build views (not space, map, or the menu).
	local hide = (not info) or info.isMenu or info.mapMode or (info.bodyId ~= "planet")
	if not hide then
		local p = state.position
		local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		local alt = r - (info.bodyRadius or self._groundR)
		if alt > (Config.TERRAIN.streamOutAlt + 800) then
			hide = true
		end
	end

	if hide then
		if self._visible then
			self._visible = false
			self._model.Parent = nil
		end
		return
	end
	if not self._visible then
		self._visible = true
		self._model.Parent = Workspace
	end
	self._model:PivotTo(frameFromUp(self._origin:ToRender(self._siteSim), self._up))
end

return LaunchSiteController
