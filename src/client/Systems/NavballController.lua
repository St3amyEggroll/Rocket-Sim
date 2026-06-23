--[[
	NavballController
	The flight attitude indicator (bottom-centre), KSP-styled:
	  * a clipped ball with a sky/ground artificial HORIZON that pitches and rolls with
	    the craft, plus a heading readout,
	  * prograde / retrograde / radial / normal markers drawn as KSP-like icons,
	  * a throttle bar, and
	  * a SAS control panel of clickable mode icons (the active one lit).
	Visible only in Flight view.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local NavballController = {}

local RADIUS = 96
local PRO = Color3.fromRGB(246, 240, 120) -- prograde / retrograde (yellow)
local RAD = Color3.fromRGB(120, 210, 255) -- radial (cyan)
local NRM = Color3.fromRGB(200, 130, 255) -- normal (purple)
local SKY = Color3.fromRGB(86, 150, 224)
local GROUND = Color3.fromRGB(120, 92, 60)
local LIT = Color3.fromRGB(120, 255, 150) -- active SAS highlight

local function corner(inst, scale)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale or 1, 0)
	c.Parent = inst
	return c
end

local function frame(parent, size, pos, color, zindex)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = size
	f.Position = pos or UDim2.fromScale(0.5, 0.5)
	f.BackgroundColor3 = color or Color3.fromRGB(255, 255, 255)
	f.BorderSizePixel = 0
	f.ZIndex = zindex or 6
	f.Parent = parent
	return f
end

-- A hollow ring (UIStroke), optional filled centre.
local function ring(parent, d, color, thick, fillTransp, zindex)
	local r = frame(parent, UDim2.fromOffset(d, d), nil, Color3.fromRGB(0, 0, 0), zindex)
	r.BackgroundTransparency = fillTransp or 1
	r.BackgroundColor3 = color
	corner(r, 1)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick or 2.5
	s.Parent = r
	return r
end

-- A small radial tick / spoke just outside a marker ring (KSP prograde "rays").
local function spoke(parent, angDeg, dist, len, thick, color, zindex)
	local b = frame(parent, UDim2.fromOffset(thick, len), nil, color, zindex)
	local a = math.rad(angDeg)
	b.Position = UDim2.new(0.5, math.cos(a) * dist, 0.5, math.sin(a) * dist)
	b.Rotation = angDeg - 90
end

-- A diagonal bar through the centre (for the retrograde X).
local function diag(parent, rot, color, zindex)
	local b = frame(parent, UDim2.fromOffset(2, 16), nil, color, zindex)
	b.Rotation = rot
end

-- Build one velocity/orientation marker icon.
local function makeMarker(parent, kind, color)
	local m = frame(parent, UDim2.fromOffset(26, 26), nil, Color3.fromRGB(0, 0, 0), 8)
	m.BackgroundTransparency = 1
	m.Name = kind
	ring(m, 15, color, 2.4, 1, 9)
	if kind == "prograde" or kind == "radialOut" then
		local dot = frame(m, UDim2.fromOffset(5, 5), nil, color, 10)
		corner(dot, 1)
	end
	if kind == "prograde" or kind == "retrograde" then
		spoke(m, -90, 10, 6, 2, color, 9) -- top
		spoke(m, 150, 10, 6, 2, color, 9) -- lower-left
		spoke(m, 30, 10, 6, 2, color, 9) -- lower-right
	end
	if kind == "retrograde" then
		diag(m, 45, color, 10)
		diag(m, -45, color, 10)
	end
	if kind == "normal" or kind == "antinormal" then
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextSize = 12
		t.TextColor3 = color
		t.Text = (kind == "normal") and "▲" or "▼"
		t.ZIndex = 10
		t.Parent = m
	end
	return m
end

function NavballController:Init() end

function NavballController:Start()
	self._input = Registry:Get("InputController")
	local Flight = Registry:Get("FlightController")
	local Mode = Registry:Get("GameModeController")
	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))

	local function refreshVis()
		self._gui.Enabled = (Mode:GetMode() == "Flight") and not self._input:GetMapMode()
	end
	Mode.ModeChanged:Connect(refreshVis)
	self._refreshVis = refreshVis
	refreshVis()

	Flight:GetUpdatedSignal():Connect(function(state, info)
		refreshVis()
		if self._gui.Enabled then
			self:_update(state, info)
		end
	end)
end

function NavballController:_build(parent)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimNavball"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = parent
	self._gui = gui

	-- The ball: a clipped circle holding the artificial horizon.
	local ball = Instance.new("Frame")
	ball.AnchorPoint = Vector2.new(0.5, 1)
	ball.Position = UDim2.new(0.5, 0, 1, -46)
	ball.Size = UDim2.fromOffset(RADIUS * 2, RADIUS * 2)
	ball.BackgroundColor3 = SKY
	ball.BorderSizePixel = 0
	ball.ClipsDescendants = true
	ball.Parent = gui
	corner(ball, 1)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(180, 190, 205)
	stroke.Thickness = 3
	stroke.Parent = ball
	self._ball = ball

	-- Horizon: holder (rolls) > group (pitches) > sky / ground / horizon line.
	local holder = frame(ball, UDim2.fromOffset(RADIUS * 4, RADIUS * 4), nil, Color3.fromRGB(0, 0, 0), 2)
	holder.BackgroundTransparency = 1
	self._holder = holder
	local hgroup = frame(holder, UDim2.fromScale(1, 1), nil, Color3.fromRGB(0, 0, 0), 2)
	hgroup.BackgroundTransparency = 1
	self._hgroup = hgroup
	local sky = frame(hgroup, UDim2.new(1, 0, 0.5, 0), UDim2.fromScale(0.5, 0.25), SKY, 2)
	local grnd = frame(hgroup, UDim2.new(1, 0, 0.5, 0), UDim2.fromScale(0.5, 0.75), GROUND, 2)
	sky.ZIndex = 2
	grnd.ZIndex = 2
	frame(hgroup, UDim2.new(1, 0, 0, 2), UDim2.fromScale(0.5, 0.5), Color3.fromRGB(235, 240, 245), 3) -- horizon line

	-- Centre reticle (the nose / where you point + thrust).
	local center = Instance.new("TextLabel")
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromScale(0.5, 0.5)
	center.Size = UDim2.fromOffset(30, 30)
	center.BackgroundTransparency = 1
	center.Font = Enum.Font.GothamBold
	center.TextSize = 24
	center.TextColor3 = Color3.fromRGB(255, 220, 70)
	center.Text = "⊕"
	center.ZIndex = 11
	center.Parent = ball

	-- Heading readout (top of the ball).
	local heading = Instance.new("TextLabel")
	heading.AnchorPoint = Vector2.new(0.5, 0)
	heading.Position = UDim2.new(0.5, 0, 0, -2)
	heading.Size = UDim2.fromOffset(64, 22)
	heading.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	heading.BackgroundTransparency = 0.15
	heading.Font = Enum.Font.GothamBold
	heading.TextSize = 15
	heading.TextColor3 = Color3.fromRGB(235, 240, 245)
	heading.Text = "000°"
	heading.ZIndex = 12
	heading.Parent = ball
	corner(heading, 0.3)
	self._heading = heading

	self._mPro = makeMarker(ball, "prograde", PRO)
	self._mRetro = makeMarker(ball, "retrograde", PRO)
	self._mRadOut = makeMarker(ball, "radialOut", RAD)
	self._mRadIn = makeMarker(ball, "radialIn", RAD)
	self._mNorm = makeMarker(ball, "normal", NRM)
	self._mAnti = makeMarker(ball, "antinormal", NRM)

	-- Throttle bar (left of the ball).
	local tb = Instance.new("Frame")
	tb.AnchorPoint = Vector2.new(1, 1)
	tb.Position = UDim2.new(0.5, -RADIUS - 18, 1, -46)
	tb.Size = UDim2.fromOffset(16, RADIUS * 2)
	tb.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
	tb.BorderSizePixel = 0
	tb.Parent = gui
	corner(tb, 0.2)
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0.5, 1)
	fill.Position = UDim2.fromScale(0.5, 1)
	fill.Size = UDim2.new(1, 0, 0, 0)
	fill.BackgroundColor3 = LIT
	fill.BorderSizePixel = 0
	fill.Parent = tb
	corner(fill, 0.2)
	self._throttleFill = fill

	self:_buildSasPanel(gui)
end

-- SAS control panel (right of the ball): one clickable icon per mode, active lit.
function NavballController:_buildSasPanel(gui)
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0.5, RADIUS + 22, 1, -46)
	panel.Size = UDim2.fromOffset(96, 150)
	panel.BackgroundColor3 = Color3.fromRGB(14, 20, 26)
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 0.12)
	local pstroke = Instance.new("UIStroke")
	pstroke.Color = Color3.fromRGB(60, 120, 90)
	pstroke.Thickness = 1.5
	pstroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextColor3 = Color3.fromRGB(120, 220, 160)
	title.Text = "SAS"
	title.Parent = panel

	local grid = Instance.new("Frame")
	grid.Position = UDim2.fromOffset(8, 22)
	grid.Size = UDim2.new(1, -16, 1, -30)
	grid.BackgroundTransparency = 1
	grid.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(36, 36)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = grid

	-- mode id -> icon kind (Ascent has no marker, uses a glyph).
	local modes = {
		{ mode = "Prograde", kind = "prograde", color = PRO },
		{ mode = "Retrograde", kind = "retrograde", color = PRO },
		{ mode = "RadialOut", kind = "radialOut", color = RAD },
		{ mode = "RadialIn", kind = "radialIn", color = RAD },
		{ mode = "Ascent", kind = "ascent", color = Color3.fromRGB(150, 220, 255) },
	}
	self._sasButtons = {}
	for _, m in ipairs(modes) do
		local b = Instance.new("TextButton")
		b.BackgroundColor3 = Color3.fromRGB(26, 32, 40)
		b.BorderSizePixel = 0
		b.Text = ""
		b.AutoButtonColor = true
		b.Parent = grid
		corner(b, 0.2)
		if m.kind == "ascent" then
			local g = Instance.new("TextLabel")
			g.Size = UDim2.fromScale(1, 1)
			g.BackgroundTransparency = 1
			g.Font = Enum.Font.GothamBold
			g.TextSize = 18
			g.TextColor3 = m.color
			g.Text = "⤒"
			g.Parent = b
		else
			makeMarker(b, m.kind, m.color)
		end
		local st = Instance.new("UIStroke")
		st.Color = LIT
		st.Thickness = 2
		st.Enabled = false
		st.Parent = b
		b.Activated:Connect(function()
			self._input:SetSAS(m.mode)
		end)
		self._sasButtons[m.mode] = { btn = b, stroke = st }
	end
end

-- Project a world direction onto the ball (front hemisphere = exact; back = clamped to rim).
local function place(marker, d, right, up, look)
	local fb = d:Dot(look)
	local x, y = d:Dot(right), d:Dot(up)
	local off
	if fb >= 0 then
		off = Vector2.new(x, -y) * RADIUS
	else
		local v = Vector2.new(x, -y)
		off = (v.Magnitude > 1e-3 and v.Unit or Vector2.new(0, 1)) * RADIUS
	end
	marker.Position = UDim2.new(0.5, off.X, 0.5, off.Y)
	marker.Visible = true
	for _, c in ipairs(marker:GetChildren()) do
		if c:IsA("GuiObject") then
			c.Visible = true
		end
	end
	marker.BackgroundTransparency = 1
end

function NavballController:_update(state, info)
	local att = info and info.attitude
	if not att then
		return
	end
	local right, up, look = att.RightVector, att.UpVector, att.LookVector

	local p = state.position
	local radOut = Vector3.new(p.x, p.y, p.z)
	radOut = (radOut.Magnitude > 1e-3) and radOut.Unit or Vector3.yAxis

	-- Artificial horizon: pitch = nose above the local horizon; roll = bank about the nose.
	local pitch = math.clamp(look:Dot(radOut), -1, 1)
	local hUp = radOut - look * look:Dot(radOut)
	hUp = (hUp.Magnitude > 1e-3) and hUp.Unit or up
	local hRight = look:Cross(hUp)
	local roll = math.atan2(right:Dot(hUp), up:Dot(hUp))
	self._holder.Rotation = math.deg(roll)
	self._hgroup.Position = UDim2.new(0.5, 0, 0.5, pitch * RADIUS)

	-- Heading (compass): nose's horizontal direction relative to the pole-ward "north".
	local north = Vector3.yAxis - radOut * radOut:Dot(Vector3.yAxis)
	if north.Magnitude < 1e-3 then
		north = Vector3.xAxis - radOut * radOut:Dot(Vector3.xAxis)
	end
	north = north.Unit
	local east = radOut:Cross(north)
	local noseH = look - radOut * look:Dot(radOut)
	if noseH.Magnitude > 1e-3 then
		noseH = noseH.Unit
		local hdg = math.deg(math.atan2(noseH:Dot(east), noseH:Dot(north)))
		if hdg < 0 then
			hdg += 360
		end
		self._heading.Text = string.format("%03d°", math.floor(hdg + 0.5) % 360)
	end

	-- Velocity / orientation markers.
	local v = state.velocity
	local vel = Vector3.new(v.x, v.y, v.z)
	local pro = (vel.Magnitude > 1e-3) and vel.Unit or look
	local norm = radOut:Cross(pro)
	norm = (norm.Magnitude > 1e-3) and norm.Unit or up

	place(self._mPro, pro, right, up, look)
	place(self._mRetro, -pro, right, up, look)
	place(self._mRadOut, radOut, right, up, look)
	place(self._mRadIn, -radOut, right, up, look)
	place(self._mNorm, norm, right, up, look)
	place(self._mAnti, -norm, right, up, look)

	self._throttleFill.Size = UDim2.new(1, 0, (info.throttle or 0), 0)

	-- Light the active SAS mode.
	local sas = info.sas
	for mode, e in pairs(self._sasButtons) do
		e.stroke.Enabled = (mode == sas)
		e.btn.BackgroundColor3 = (mode == sas) and Color3.fromRGB(34, 56, 42) or Color3.fromRGB(26, 32, 40)
	end
end

return NavballController
