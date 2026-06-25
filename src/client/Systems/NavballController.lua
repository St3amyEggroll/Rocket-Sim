--[[
	NavballController
	The flight attitude indicator (bottom-centre), KSP-styled.

	The ball is a CIRCULAR frame whose background is a UIGradient sky/ground horizon:
	rotating the gradient gives roll, moving its colour transition gives pitch. (A
	rounded frame clips its own gradient to a circle, unlike ClipsDescendants which only
	clips to a rectangle -- that's why the old version looked square.) On top sit the
	prograde/retrograde/radial/normal markers, a heading readout and the nose reticle.
	A SAS panel of clickable mode icons sits to the right. Visible only in Flight view.
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
local SKY = Color3.fromRGB(92, 156, 226)
local GROUND = Color3.fromRGB(122, 92, 58)
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

-- A thin horizontal line on the ball (the horizon / a pitch-ladder rung). Width is set per frame.
local function makeLine(parent, thick, color, transparency)
	local l = Instance.new("Frame")
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Size = UDim2.fromOffset(2, thick)
	l.BackgroundColor3 = color
	l.BackgroundTransparency = transparency or 0.1
	l.BorderSizePixel = 0
	l.ZIndex = 5
	l.Parent = parent
	return l
end

-- Place a line at signed distance `distPx` along the ball's vertical (gradient) axis
-- (axisX,axisY), fit to the circle's chord at that height and rolled to match attitude.
local function setLine(line, axisX, axisY, distPx, maxLen, rollDeg)
	if math.abs(distPx) >= RADIUS - 1 then
		line.Visible = false
		return
	end
	line.Visible = true
	local chord = 2 * math.sqrt(RADIUS * RADIUS - distPx * distPx)
	local len = maxLen and math.min(chord, maxLen) or chord
	line.Size = UDim2.fromOffset(len, line.Size.Y.Offset)
	line.Position = UDim2.new(0.5, axisX * distPx, 0.5, axisY * distPx)
	line.Rotation = rollDeg
end

-- A circular shading overlay (top highlight / bottom shadow) so the disc reads as a 3D ball.
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
	z = z or 8
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

	-- The ball: a CIRCULAR frame; its UIGradient background is the sky/ground horizon.
	local ball = Instance.new("Frame")
	ball.AnchorPoint = Vector2.new(0.5, 1)
	ball.Position = UDim2.new(0.5, 0, 1, -44)
	ball.Size = UDim2.fromOffset(RADIUS * 2, RADIUS * 2)
	ball.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ball.BorderSizePixel = 0
	ball.Parent = gui
	corner(ball, 1)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(190, 200, 214)
	stroke.Thickness = 3
	stroke.Parent = ball
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Parent = ball
	self._ball = ball
	self._grad = grad

	-- Spherical shading: a soft highlight up top and a shadow at the bottom give the flat disc
	-- some 3D depth (a ball lit from above).
	shadeOverlay(ball, Color3.fromRGB(255, 255, 255), NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 1),
	}))
	shadeOverlay(ball, Color3.fromRGB(0, 0, 0), NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 0.78),
	}))

	-- Horizon line + pitch-ladder rungs (drawn over the gradient; positioned each frame).
	self._horizon = makeLine(ball, 3, Color3.fromRGB(245, 248, 252), 0.05)
	self._rungs = {}
	for _, f in ipairs({ -2 / 3, -1 / 3, 1 / 3, 2 / 3 }) do
		self._rungs[#self._rungs + 1] = { line = makeLine(ball, 2, Color3.fromRGB(208, 215, 226), 0.4), px = f * RADIUS }
	end

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
	center.ZIndex = 14
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
	heading.ZIndex = 15
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

	-- Horizon via the gradient: pitch moves the sky/ground transition, roll rotates it.
	local pitch = math.clamp(look:Dot(radOut), -1, 1)
	local hUp = radOut - look * look:Dot(radOut)
	hUp = (hUp.Magnitude > 1e-3) and hUp.Unit or up
	local roll = math.atan2(right:Dot(hUp), up:Dot(hUp))
	self._grad.Rotation = 90 + math.deg(roll)
	local t = math.clamp(0.5 + pitch * 0.5, 0.02, 0.98)
	self._grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, SKY),
		ColorSequenceKeypoint.new(math.max(t - 0.012, 0.01), SKY),
		ColorSequenceKeypoint.new(t, GROUND),
		ColorSequenceKeypoint.new(1, GROUND),
	})

	-- Horizon line + pitch ladder, aligned to the gradient transition and rolled to match.
	local rollDeg = math.deg(roll)
	local axisX, axisY = -math.sin(roll), math.cos(roll)
	local hp = pitch * RADIUS
	setLine(self._horizon, axisX, axisY, hp, nil, rollDeg)
	for _, rung in ipairs(self._rungs) do
		setLine(rung.line, axisX, axisY, hp + rung.px, RADIUS * 0.5, rollDeg)
	end

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
