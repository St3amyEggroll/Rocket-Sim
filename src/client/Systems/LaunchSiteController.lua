--[[
	LaunchSiteController
	Owner of: the launch site's ground structures -- a raised launch PAD (concrete platform +
	hold-down mount + service/gantry tower), the VAB BUILDING, and a crawlerway between them.

	The structures live at the fixed equatorial launch site, oriented radial-out, with the pad
	deck Config.LAUNCH.padHeight studs above the terrain (the craft's base sits on it). They are
	shown only while the craft is near Terra's surface (like the streamed terrain) -- hidden in
	space, in map view, and behind the menu cinematic. The whole site is one Model, re-pivoted
	each frame through the floating origin so it stays put as the world rebases.
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
local BUILDING = Color3.fromRGB(120, 124, 132)
local TRIM = Color3.fromRGB(58, 92, 150)
local DOOR = Color3.fromRGB(40, 52, 80)

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
	-- launch mount (the dark deck the rocket stands on) + a flame hole in the middle.
	box(model, Vector3.new(30, 3, 30), METALDARK, Enum.Material.DiamondPlate, at(0, padH + 1.5, 0))
	box(model, Vector3.new(12, 5, 12), Color3.fromRGB(18, 18, 22), Enum.Material.SmoothPlastic, at(0, padH + 0.5, 0))
	-- hold-down clamps ringing the mount.
	for i = 0, 3 do
		local a = i * math.pi / 2
		box(model, Vector3.new(2.5, 9, 2.5), STEEL, Enum.Material.Metal, at(math.cos(a) * 11, padH + 4, math.sin(a) * 11))
	end

	-- ---- Service / gantry tower beside the pad ----
	local towerX, towerH, legR = 32, 80, 6
	for _, lx in ipairs({ towerX - legR, towerX + legR }) do
		for _, lz in ipairs({ -legR, legR }) do
			box(model, Vector3.new(2, towerH, 2), STEEL, Enum.Material.Metal, at(lx, padH + towerH / 2, lz))
		end
	end
	for _, ly in ipairs({ padH + 18, padH + 44, padH + 70 }) do
		box(model, Vector3.new(legR * 2 + 2, 1.5, 2), STEEL, Enum.Material.Metal, at(towerX, ly, -legR))
		box(model, Vector3.new(legR * 2 + 2, 1.5, 2), STEEL, Enum.Material.Metal, at(towerX, ly, legR))
		box(model, Vector3.new(2, 1.5, legR * 2 + 2), STEEL, Enum.Material.Metal, at(towerX - legR, ly, 0))
		box(model, Vector3.new(2, 1.5, legR * 2 + 2), STEEL, Enum.Material.Metal, at(towerX + legR, ly, 0))
	end
	-- crew access arm reaching from the tower toward the rocket.
	box(model, Vector3.new(towerX - legR - 4, 2.5, 5), STEEL, Enum.Material.Metal, at((towerX - legR - 4) / 2 + 4, padH + 56, 0))

	-- ---- VAB building + low bay, set back from the pad ----
	local vx = -160
	box(model, Vector3.new(110, 138, 100), BUILDING, Enum.Material.Concrete, at(vx, 138 / 2, 0)) -- tall high bay
	box(model, Vector3.new(114, 6, 104), TRIM, Enum.Material.SmoothPlastic, at(vx, 138 + 1, 0)) -- roof trim
	-- twin bay doors on the face toward the pad (+X face at x = vx + 55).
	box(model, Vector3.new(1.5, 96, 34), DOOR, Enum.Material.SmoothPlastic, at(vx + 55, 96 / 2, -22))
	box(model, Vector3.new(1.5, 96, 34), DOOR, Enum.Material.SmoothPlastic, at(vx + 55, 96 / 2, 22))
	box(model, Vector3.new(72, 58, 84), STEEL, Enum.Material.Concrete, at(vx - 88, 58 / 2, 0)) -- low bay annex

	-- crawlerway connecting the VAB to the pad.
	box(model, Vector3.new(120, 1, 28), DARKCON, Enum.Material.Concrete, at(-67, 0.5, 0))

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
