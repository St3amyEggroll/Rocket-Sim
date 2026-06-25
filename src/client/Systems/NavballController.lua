--[[
	NavballController
	The flight attitude indicator (bottom-centre): a 3D navball software-projected into a 2D disc.

	Each frame the craft's attitude defines a world basis (radial-out = the ball's zenith, with a
	pole-ward "north" and "east"); we project a unit sphere's latitude/longitude grid through the
	craft's right/up/look axes onto the disc, drawing the visible (front) hemisphere as curved
	gridlines plus a red horizon great-circle and pitch numbers -- so it reads as a real rotating
	ball. A sky/ground gradient fills behind it; prograde/retrograde/radial/normal markers, a nose
	reticle, a heading readout, a throttle bar and a SAS panel sit on top. Flight view only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local NavballController = {}

local RADIUS = 92
local PRO = Color3.fromRGB(246, 240, 120) -- prograde / retrograde (yellow)
local RAD = Color3.fromRGB(120, 210, 255) -- radial (cyan)
local NRM = Color3.fromRGB(200, 130, 255) -- normal (purple)
local SKY = Color3.fromRGB(74, 150, 224)
local GROUND = Color3.fromRGB(170, 132, 80)
local GRID = Color3.fromRGB(238, 243, 250)
local HORIZON = Color3.fromRGB(226, 64, 60)
local LIT = Color3.fromRGB(120, 255, 150) -- active SAS highlight

-- Grid layout: latitude rings (pitch) and longitude meridians (heading).
local LON_STEP = 45 -- meridian every this many degrees
local LON_SEG = 18 -- samples around a latitude ring
local LAT_SEG = 12 -- samples along a meridian (lat -80..80)
local FRONT = 0.04 -- a point is on the visible hemisphere when dir.look > this

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
	f.ZIndex = zindex or 8
	f.Parent = parent
	return f
end

local function ring(parent, d, color, thick, zindex)
	local r = frame(parent, UDim2.fromOffset(d, d), nil, color, zindex)
	r.BackgroundTransparency = 1
	corner(r, 1)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick or 2.4
	s.Parent = r
	return r
end

local function spoke(parent, angDeg, dist, len, thick, color, zindex)
	local b = frame(parent, UDim2.fromOffset(thick, len), nil, color, zindex)
	local a = math.rad(angDeg)
	b.Position = UDim2.new(0.5, math.cos(a) * dist, 0.5, math.sin(a) * dist)
	b.Rotation = angDeg - 90
end

local function diag(parent, rot, color, zindex)
	local b = frame(parent, UDim2.fromOffset(2, 15), nil, color, zindex)
	b.Rotation = rot
end

-- A circular shading overlay (top highlight / bottom shadow) for 3D depth.
local function shadeOverlay(parent, color, transparencySeq)
	local o = Instance.new("Frame")
	o.AnchorPoint = Vector2.new(0.5, 0.5)
	o.Position = UDim2.fromScale(0.5, 0.5)
	o.Size = UDim2.fromScale(1, 1)
	o.BackgroundColor3 = color
	o.BorderSizePixel = 0
	o.ZIndex = 2
	o.Parent = parent
	corner(o, 1)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(color)
	g.Transparency = transparencySeq
	g.Parent = o
	return o
end

-- Build one prograde/retrograde/radial/normal marker icon.
local function makeMarker(parent, kind, color, z)
	z = z or 10
	local m = frame(parent, UDim2.fromOffset(24, 24), nil, color, z)
	m.BackgroundTransparency = 1
	m.Name = kind
	ring(m, 14, color, 2.2, z + 1)
	if kind == "prograde" or kind == "radialOut" then
		local dot = frame(m, UDim2.fromOffset(4, 4), nil, color, z + 2)
		corner(dot, 1)
	end
	if kind == "prograde" or kind == "retrograde" then
		spoke(m, -90, 9, 5, 2, color, z + 1)
		spoke(m, 150, 9, 5, 2, color, z + 1)
		spoke(m, 30, 9, 5, 2, color, z + 1)
	end
	if kind == "retrograde" then
		diag(m, 45, color, z + 2)
		diag(m, -45, color, z + 2)
	end
	if kind == "normal" or kind == "antinormal" then
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextSize = 11
		t.TextColor3 = color
		t.Text = (kind == "normal") and "▲" or "▼"
		t.ZIndex = z + 2
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

	-- The ball: a CIRCULAR frame; its UIGradient background is the soft sky/ground fill (the
	-- crisp horizon + gridlines are drawn over it by the projection).
	local ball = Instance.new("Frame")
	ball.AnchorPoint = Vector2.new(0.5, 1)
	ball.Position = UDim2.new(0.5, 0, 1, -44)
	ball.Size = UDim2.fromOffset(RADIUS * 2, RADIUS * 2)
	ball.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ball.BorderSizePixel = 0
	ball.Parent = gui
	corner(ball, 1)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(206, 214, 226)
	stroke.Thickness = 3
	stroke.Parent = ball
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = ball
	self._ball = ball
	self._grad = grad

	-- Spherical shading (top highlight, bottom shadow).
	shadeOverlay(ball, Color3.fromRGB(255, 255, 255), NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	}))
	shadeOverlay(ball, Color3.fromRGB(0, 0, 0), NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 0.8),
	}))

	-- Pools for the projected gridline segments + pitch numbers.
	self._segPool, self._segUsed = {}, 0
	self._numPool, self._numUsed = {}, 0

	-- Centre reticle (the nose / where you point + thrust).
	local center = Instance.new("TextLabel")
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromScale(0.5, 0.5)
	center.Size = UDim2.fromOffset(30, 30)
	center.BackgroundTransparency = 1
	center.Font = Enum.Font.GothamBold
	center.TextSize = 26
	center.TextColor3 = Color3.fromRGB(255, 220, 70)
	center.Text = "⊕"
	center.ZIndex = 16
	center.Parent = ball

	-- Heading readout (top of the ball).
	local heading = Instance.new("TextLabel")
	heading.AnchorPoint = Vector2.new(0.5, 0.5)
	heading.Position = UDim2.new(0.5, 0, 0, 2)
	heading.Size = UDim2.fromOffset(58, 22)
	heading.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	heading.BackgroundTransparency = 0.1
	heading.Font = Enum.Font.GothamBold
	heading.TextSize = 15
	heading.TextColor3 = Color3.fromRGB(235, 240, 245)
	heading.Text = "000°"
	heading.ZIndex = 17
	heading.Parent = ball
	corner(heading, 0.35)
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
	tb.Position = UDim2.new(0.5, -RADIUS - 18, 1, -44)
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

function NavballController:_buildSasPanel(gui)
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0.5, RADIUS + 22, 1, -44)
	panel.Size = UDim2.fromOffset(96, 150)
	panel.BackgroundColor3 = Color3.fromRGB(14, 20, 26)
	panel.BackgroundTransparency = 0.1
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

	local gridFrame = Instance.new("Frame")
	gridFrame.Position = UDim2.fromOffset(8, 22)
	gridFrame.Size = UDim2.new(1, -16, 1, -30)
	gridFrame.BackgroundTransparency = 1
	gridFrame.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(36, 36)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = gridFrame

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
		b.Parent = gridFrame
		corner(b, 0.2)
		if m.kind == "ascent" then
			local g = Instance.new("TextLabel")
			g.Size = UDim2.fromScale(1, 1)
			g.BackgroundTransparency = 1
			g.Font = Enum.Font.GothamBold
			g.TextSize = 20
			g.TextColor3 = m.color
			g.Text = "↑"
			g.Parent = b
		else
			makeMarker(b, m.kind, m.color, 2)
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

-- ---- projected gridline pool ----

function NavballController:_seg(p1, p2, color, thick)
	self._segUsed += 1
	local s = self._segPool[self._segUsed]
	if not s then
		s = Instance.new("Frame")
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.BorderSizePixel = 0
		s.ZIndex = 5
		s.Parent = self._ball
		self._segPool[self._segUsed] = s
	end
	local dx, dy = p2.X - p1.X, p2.Y - p1.Y
	local len = math.sqrt(dx * dx + dy * dy)
	s.Visible = true
	s.Size = UDim2.fromOffset(math.max(len, 1), thick)
	s.Position = UDim2.new(0.5, (p1.X + p2.X) * 0.5, 0.5, (p1.Y + p2.Y) * 0.5)
	s.Rotation = math.deg(math.atan2(dy, dx))
	s.BackgroundColor3 = color
	s.BackgroundTransparency = 0.05
end

function NavballController:_num(pos, text)
	self._numUsed += 1
	local l = self._numPool[self._numUsed]
	if not l then
		l = Instance.new("TextLabel")
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBold
		l.TextSize = 12
		l.TextColor3 = Color3.fromRGB(244, 247, 252)
		l.TextStrokeTransparency = 0.35
		l.Size = UDim2.fromOffset(26, 14)
		l.ZIndex = 6
		l.Parent = self._ball
		self._numPool[self._numUsed] = l
	end
	l.Visible = true
	l.Position = UDim2.new(0.5, pos.X, 0.5, pos.Y)
	l.Text = text
end

-- Draw the navball grid by projecting a unit sphere through the craft axes. `radOut/north/east`
-- are the local-horizon world basis (zenith = radOut); right/up/look are the craft axes.
function NavballController:_drawGrid(right, up, look, radOut, north, east)
	local function project(dir)
		if dir:Dot(look) < FRONT then
			return nil
		end
		return Vector2.new(dir:Dot(right) * RADIUS, -dir:Dot(up) * RADIUS)
	end
	local function pt(latR, lonR)
		local cl, sl = math.cos(latR), math.sin(latR)
		return (north * math.cos(lonR) + east * math.sin(lonR)) * cl + radOut * sl
	end

	-- Latitude rings (+ the red horizon at lat 0).
	local lats = { 0, -60, -30, 30, 60 }
	for _, latDeg in ipairs(lats) do
		local latR = math.rad(latDeg)
		local color = (latDeg == 0) and HORIZON or GRID
		local thick = (latDeg == 0) and 3 or 2
		local prev
		for k = 0, LON_SEG do
			local p = project(pt(latR, (k / LON_SEG) * 2 * math.pi))
			if p and prev then
				self:_seg(prev, p, color, thick)
			end
			prev = p
		end
	end

	-- Longitude meridians.
	for lonDeg = 0, 359, LON_STEP do
		local lonR = math.rad(lonDeg)
		local prev
		for k = -LAT_SEG, LAT_SEG do
			local p = project(pt((k / LAT_SEG) * math.rad(80), lonR))
			if p and prev then
				self:_seg(prev, p, GRID, 1.5)
			end
			prev = p
		end
	end

	-- Pitch numbers: each latitude line's label where it crosses the central column.
	for _, latDeg in ipairs({ 30, 60, -30, -60 }) do
		local latR = math.rad(latDeg)
		local best, bestp
		for k = 0, LON_SEG do
			local p = project(pt(latR, (k / LON_SEG) * 2 * math.pi))
			if p and (not best or math.abs(p.X) < best) then
				best, bestp = math.abs(p.X), p
			end
		end
		if bestp and best < RADIUS * 0.55 then
			self:_num(bestp, tostring(math.abs(latDeg)))
		end
	end
end

-- Position a marker on the ball; hide it when behind the camera or when not shown.
local function place(marker, d, right, up, look, show)
	if not show then
		marker.Visible = false
		return
	end
	local fb = d:Dot(look)
	if fb < -0.04 then
		marker.Visible = false
		return
	end
	marker.Visible = true
	local off = Vector2.new(d:Dot(right), -d:Dot(up)) * RADIUS
	marker.Position = UDim2.new(0.5, off.X, 0.5, off.Y)
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

	-- Pole-ward "north" + "east" in the local horizon (same reference the heading uses).
	local north = Vector3.yAxis - radOut * radOut:Dot(Vector3.yAxis)
	if north.Magnitude < 1e-3 then
		north = Vector3.xAxis - radOut * radOut:Dot(Vector3.xAxis)
	end
	north = north.Unit
	local east = radOut:Cross(north)

	-- Soft sky/ground fill behind the grid (the projected red line is the crisp horizon).
	local pitch = math.clamp(look:Dot(radOut), -1, 1)
	local roll = math.atan2(right:Dot(radOut - look * look:Dot(radOut)), up:Dot(radOut - look * look:Dot(radOut)))
	self._grad.Rotation = 90 + math.deg(roll)
	local t = math.clamp(0.5 + pitch * 0.5, 0.05, 0.95)
	self._grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, SKY),
		ColorSequenceKeypoint.new(math.clamp(t - 0.16, 0.02, 0.97), SKY),
		ColorSequenceKeypoint.new(math.clamp(t + 0.16, 0.03, 0.98), GROUND),
		ColorSequenceKeypoint.new(1, GROUND),
	})

	-- Projected sphere grid.
	self._segUsed, self._numUsed = 0, 0
	self:_drawGrid(right, up, look, radOut, north, east)
	for i = self._segUsed + 1, #self._segPool do
		self._segPool[i].Visible = false
	end
	for i = self._numUsed + 1, #self._numPool do
		self._numPool[i].Visible = false
	end

	-- Heading (compass): nose's horizontal direction relative to north.
	local noseH = look - radOut * look:Dot(radOut)
	if noseH.Magnitude > 1e-3 then
		noseH = noseH.Unit
		local hdg = math.deg(math.atan2(noseH:Dot(east), noseH:Dot(north)))
		if hdg < 0 then
			hdg += 360
		end
		self._heading.Text = string.format("%03d°", math.floor(hdg + 0.5) % 360)
	end

	-- Markers. Velocity-relative ones hide when nearly stationary (no meaningful heading).
	local v = state.velocity
	local vel = Vector3.new(v.x, v.y, v.z)
	local hasVel = vel.Magnitude > 1.5
	local pro = hasVel and vel.Unit or look
	local norm = radOut:Cross(pro)
	norm = (norm.Magnitude > 1e-3) and norm.Unit or up

	place(self._mPro, pro, right, up, look, hasVel)
	place(self._mRetro, -pro, right, up, look, hasVel)
	place(self._mRadOut, radOut, right, up, look, true)
	place(self._mRadIn, -radOut, right, up, look, true)
	place(self._mNorm, norm, right, up, look, hasVel)
	place(self._mAnti, -norm, right, up, look, hasVel)

	self._throttleFill.Size = UDim2.new(1, 0, (info.throttle or 0), 0)

	local sas = info.sas
	for mode, e in pairs(self._sasButtons) do
		e.stroke.Enabled = (mode == sas)
		e.btn.BackgroundColor3 = (mode == sas) and Color3.fromRGB(34, 56, 42) or Color3.fromRGB(26, 32, 40)
	end
end

return NavballController
