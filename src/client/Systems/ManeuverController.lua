--[[
	ManeuverController
	A KSP-style maneuver node: a planned burn placed at a future point on the craft's orbit,
	with prograde / normal / radial delta-v you set by DRAGGING handles on the map. The map draws
	the resulting post-burn orbit (the trajectory predictor); a burn HUD shows total delta-v,
	time-to-node, and the estimated burn duration; the navball shows a node marker to point at.

	The node owns only its plan (absolute mission time + the three delta-v components). Each frame
	we propagate the CURRENT craft state to the node, build the orbital basis there, apply the
	delta-v, and re-propagate to predict the post-burn conic -- so the plan tracks your live orbit.
	MapViewController reads GetPrediction() to draw it; NavballController reads GetBurnDir().
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local ManeuverController = {}

local PRO = Color3.fromRGB(246, 240, 120)
local NRM = Color3.fromRGB(200, 130, 255)
local RAD = Color3.fromRGB(120, 210, 255)
local NODE = Color3.fromRGB(90, 170, 255)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)

local BASE_OFF = 30 -- handle resting distance from the node (px)
local PX_PER_DV = 0.7 -- screen px per m/s when dragging a handle
local AXIS_LEN = 600 -- render-space length used to project an axis direction to screen

-- The six pull handles: which delta-v axis they drive and in which sign.
local HANDLES = {
	{ key = "pro", sign = 1, color = PRO, name = "prograde" },
	{ key = "pro", sign = -1, color = PRO, name = "retrograde" },
	{ key = "nrm", sign = 1, color = NRM, name = "normal" },
	{ key = "nrm", sign = -1, color = NRM, name = "anti-normal" },
	{ key = "rad", sign = 1, color = RAD, name = "radial out" },
	{ key = "rad", sign = -1, color = RAD, name = "radial in" },
}

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

function ManeuverController:Init()
	self._node = nil -- { mt = absoluteMissionTime, pro=, nrm=, rad= }
end

function ManeuverController:Start()
	self._mode = Registry:Get("GameModeController")
	self._input = Registry:Get("InputController")
	self._vehicle = Registry:Get("VehicleController")
	self._map = Registry:Get("MapViewController")
	local Flight = Registry:Get("FlightController")

	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)

	-- Drag handling: a handle's button captures the press, then global move/release drive it.
	UserInputService.InputChanged:Connect(function(input)
		if self._dragHandle and input.UserInputType == Enum.UserInputType.MouseMovement then
			self:_drag(UserInputService:GetMouseLocation())
		elseif self._dragHandle and input.UserInputType == Enum.UserInputType.Touch then
			self:_drag(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if self._dragHandle and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			self._dragHandle = nil
		end
	end)
end

-- ------------------------------------------------------------------ UI ----

function ManeuverController:_build(pg)
	-- Controls + burn readout (bottom centre; the navball is hidden in map view).
	local gui = Instance.new("ScreenGui")
	gui.Name = "ManeuverUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 64
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -14)
	bar.Size = UDim2.fromOffset(420, 64)
	bar.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	bar.BackgroundTransparency = 0.15
	bar.BorderSizePixel = 0
	corner(bar, 10)
	bar.Parent = gui

	local function btn(text, x, w, color)
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(x, 8)
		b.Size = UDim2.fromOffset(w, 26)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.Text = text
		corner(b, 6)
		b.Parent = bar
		return b
	end

	btn("+ Node", 10, 86, Color3.fromRGB(60, 110, 160)).Activated:Connect(function()
		self:_addNode()
	end)
	btn("◀", 102, 36, Color3.fromRGB(48, 54, 66)).Activated:Connect(function()
		self:_shiftNode(-1)
	end)
	btn("▶", 142, 36, Color3.fromRGB(48, 54, 66)).Activated:Connect(function()
		self:_shiftNode(1)
	end)
	btn("Clear", 182, 64, Color3.fromRGB(120, 60, 60)).Activated:Connect(function()
		self._node = nil
	end)

	self._readout = Instance.new("TextLabel")
	self._readout.Position = UDim2.fromOffset(10, 38)
	self._readout.Size = UDim2.fromOffset(400, 20)
	self._readout.BackgroundTransparency = 1
	self._readout.Font = Enum.Font.Code
	self._readout.TextSize = 13
	self._readout.TextXAlignment = Enum.TextXAlignment.Left
	self._readout.TextColor3 = DIM
	self._readout.Text = "Drag a part-coloured handle on the node to plan a burn."
	self._readout.Parent = bar

	self._hint = Instance.new("TextLabel")
	self._hint.AnchorPoint = Vector2.new(1, 0)
	self._hint.Position = UDim2.new(1, -10, 0, 10)
	self._hint.Size = UDim2.fromOffset(150, 20)
	self._hint.BackgroundTransparency = 1
	self._hint.Font = Enum.Font.GothamBold
	self._hint.TextSize = 13
	self._hint.TextXAlignment = Enum.TextXAlignment.Right
	self._hint.TextColor3 = NODE
	self._hint.Text = ""
	self._hint.Parent = bar

	-- Handle dots (separate gui, drawn on top of the map).
	local hgui = Instance.new("ScreenGui")
	hgui.Name = "ManeuverHandles"
	hgui.ResetOnSpawn = false
	hgui.IgnoreGuiInset = true
	hgui.DisplayOrder = 66
	hgui.Enabled = false
	hgui.Parent = pg
	self._hgui = hgui

	self._handles = {}
	for i, h in ipairs(HANDLES) do
		local dot = Instance.new("TextButton")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(20, 20)
		dot.BackgroundColor3 = h.color
		dot.BorderSizePixel = 0
		dot.Text = ""
		dot.AutoButtonColor = true
		corner(dot, 10)
		local st = Instance.new("UIStroke")
		st.Color = Color3.fromRGB(20, 24, 30)
		st.Thickness = 2
		st.Parent = dot
		dot.Visible = false
		dot.Parent = hgui
		dot.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				self._dragHandle = i
			end
		end)
		self._handles[i] = dot
	end
end

-- ----------------------------------------------------------- node plan ----

function ManeuverController:_addNode()
	local st, info = self._lastState, self._lastInfo
	if not st or not info or info.mode ~= "Flight" then
		return
	end
	local ro = Orbit.getReadout(st, info.mu)
	local lead = (ro.period and ro.period < math.huge) and math.clamp(ro.period * 0.5, 20, ro.period) or 120
	self._node = { mt = (info.missionTime or 0) + lead, pro = 0, nrm = 0, rad = 0 }
end

function ManeuverController:_shiftNode(dir)
	if not self._node or not self._lastInfo then
		return
	end
	local ro = Orbit.getReadout(self._lastState, self._lastInfo.mu)
	local step = (ro.period and ro.period < math.huge) and ro.period * 0.1 or 30
	self._node.mt = math.max((self._lastInfo.missionTime or 0) + 5, self._node.mt + dir * step)
end

-- Predict the post-burn orbit from the live state. Returns nil when there's no (future) node.
-- The full 90-point sampled path is ONLY needed by the map view, so it's sampled only when
-- withPath is true; the navball burn marker just needs `dv`, computed cheaply every frame.
function ManeuverController:_predict(state, mu, mt, withPath)
	local node = self._node
	if not node then
		return nil
	end
	local dt = node.mt - mt
	if dt <= 0 then
		return nil
	end
	local atNode = Orbit.propagate(state, mu, dt)
	local p = Vector3.new(atNode.position.x, atNode.position.y, atNode.position.z)
	local v = Vector3.new(atNode.velocity.x, atNode.velocity.y, atNode.velocity.z)
	local prograde = (v.Magnitude > 1e-3) and v.Unit or Vector3.zAxis
	local h = p:Cross(v)
	local normal = (h.Magnitude > 1e-3) and h.Unit or Vector3.yAxis
	local radialOut = normal:Cross(prograde).Unit -- in-plane, perpendicular to prograde
	local dv = prograde * node.pro + normal * node.nrm + radialOut * node.rad
	local postState = { position = atNode.position, velocity = Orbit.vec(v.X + dv.X, v.Y + dv.Y, v.Z + dv.Z) }
	return {
		nodePos = p,
		prograde = prograde,
		normal = normal,
		radialOut = radialOut,
		dv = dv,
		dvMag = dv.Magnitude,
		dt = dt,
		path = withPath and Orbit.sampleOrbitPath(postState, mu, Config.ORBITLINE.segments) or nil,
	}
end

-- Read by MapViewController (post-burn orbit + node marker) and NavballController (burn dir).
function ManeuverController:GetPrediction()
	return self._pred
end
function ManeuverController:GetBurnDir()
	if self._pred and self._pred.dvMag > 0.05 then
		return self._pred.dv.Unit
	end
	return nil
end

-- ----------------------------------------------------------- per frame ----

function ManeuverController:_update(state, info)
	self._lastState, self._lastInfo = state, info
	if not info or info.mode ~= "Flight" then
		self._node = nil
		self._pred = nil
		self._gui.Enabled = false
		self._hgui.Enabled = false
		return
	end

	local mapMode = info.mapMode == true
	-- Sample the full predicted path only in map view (where it's drawn); out of map view the
	-- navball only needs the burn direction, so skip ~90 Kepler propagations per frame.
	self._pred = self:_predict(state, info.mu, info.missionTime or 0, mapMode)

	self._gui.Enabled = mapMode
	self._hgui.Enabled = mapMode and self._pred ~= nil

	if mapMode then
		self:_layoutHandles()
	end
	self:_updateReadout(info)
end

function ManeuverController:_layoutHandles()
	local pred = self._pred
	local cam = Workspace.CurrentCamera
	local scale = self._map and self._map:GetMapScale()
	if not pred or not cam or not scale then
		for _, dot in ipairs(self._handles) do
			dot.Visible = false
		end
		return
	end
	local nodeWorld = pred.nodePos * scale
	local sp0, on0 = cam:WorldToViewportPoint(nodeWorld)
	if not on0 then
		for _, dot in ipairs(self._handles) do
			dot.Visible = false
		end
		return
	end
	local node2 = Vector2.new(sp0.X, sp0.Y)
	self._nodeScreen = node2

	for i, h in ipairs(HANDLES) do
		local dir = (h.key == "pro" and pred.prograde or h.key == "nrm" and pred.normal or pred.radialOut) * h.sign
		local p1 = cam:WorldToViewportPoint(nodeWorld + dir * AXIS_LEN)
		local screenDir = Vector2.new(p1.X - sp0.X, p1.Y - sp0.Y)
		screenDir = (screenDir.Magnitude > 1e-3) and screenDir.Unit or Vector2.new(0, -1)
		self._handles[i]._screenDir = screenDir
		-- This handle juts out by the delta-v it controls (when its sign matches the value).
		local val = (self._node[h.key] or 0)
		local active = (val * h.sign) > 0.01
		local out = BASE_OFF + (active and math.abs(val) * PX_PER_DV or 0)
		local pos = node2 + screenDir * out
		local dot = self._handles[i]
		dot.Visible = true
		dot.Position = UDim2.fromOffset(pos.X, pos.Y)
	end
end

function ManeuverController:_drag(mouse)
	local i = self._dragHandle
	local pred, node = self._pred, self._node
	if not i or not pred or not node or not self._nodeScreen then
		return
	end
	local h = HANDLES[i]
	local screenDir = self._handles[i]._screenDir or Vector2.new(0, -1)
	local pull = (mouse - self._nodeScreen):Dot(screenDir) -- px along this handle's direction
	local mag = math.max(0, pull - BASE_OFF) / PX_PER_DV
	node[h.key] = h.sign * mag
end

function ManeuverController:_updateReadout(info)
	if not self._gui.Enabled then
		return
	end
	local pred = self._pred
	if not pred then
		self._readout.Text = "+ Node to plan a burn, then drag the coloured handles."
		self._readout.TextColor3 = DIM
		self._hint.Text = ""
		return
	end
	local accel = self._vehicle:GetThrustAccel(1)
	local burn = (accel and accel > 0) and (pred.dvMag / accel) or nil
	self._readout.Text = ("Δv %.1f m/s   (Pro %.0f  Nrm %.0f  Rad %.0f)"):format(
		pred.dvMag,
		self._node.pro,
		self._node.nrm,
		self._node.rad
	)
	self._readout.TextColor3 = TEXT
	local burnTxt = burn and ("  burn ~%.0fs"):format(burn) or ""
	self._hint.Text = ("T-%.0fs%s"):format(pred.dt, burnTxt)
end

return ManeuverController
