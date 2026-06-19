--[[
	NavballController
	A flight attitude indicator (bottom-centre). The centre reticle is the nose
	(where you're pointing / thrusting). Markers show, relative to your attitude,
	where prograde/retrograde and radial-out/in are, plus a throttle bar and the
	current SAS mode. Visible only in Flight view.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local NavballController = {}

local RADIUS = 96

local function dot(parent, color, symbol, hollow)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(18, 18)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = hollow and 0.6 or 0
	f.BorderSizePixel = 0
	f.ZIndex = 6
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBold
	t.TextSize = 11
	t.TextColor3 = Color3.fromRGB(10, 12, 16)
	t.Text = symbol
	t.ZIndex = 7
	t.Parent = f
	f.Parent = parent
	return f
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

	local ball = Instance.new("Frame")
	ball.AnchorPoint = Vector2.new(0.5, 1)
	ball.Position = UDim2.new(0.5, 0, 1, -48)
	ball.Size = UDim2.fromOffset(RADIUS * 2, RADIUS * 2)
	ball.BackgroundColor3 = Color3.fromRGB(20, 26, 36)
	ball.BackgroundTransparency = 0.1
	ball.BorderSizePixel = 0
	ball.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ball
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 200, 255)
	stroke.Thickness = 2
	stroke.Parent = ball
	self._ball = ball

	-- Fixed centre reticle (the nose).
	local center = Instance.new("TextLabel")
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromScale(0.5, 0.5)
	center.Size = UDim2.fromOffset(26, 26)
	center.BackgroundTransparency = 1
	center.Font = Enum.Font.GothamBold
	center.TextSize = 22
	center.TextColor3 = Color3.fromRGB(255, 235, 120)
	center.Text = "+"
	center.ZIndex = 8
	center.Parent = ball

	self._mPro = dot(ball, Color3.fromRGB(140, 255, 150), "", false)
	self._mRetro = dot(ball, Color3.fromRGB(140, 255, 150), "x", true)
	self._mRadOut = dot(ball, Color3.fromRGB(120, 200, 255), "", false)
	self._mRadIn = dot(ball, Color3.fromRGB(255, 170, 110), "", true)

	-- Throttle bar (left of the ball).
	local tb = Instance.new("Frame")
	tb.AnchorPoint = Vector2.new(1, 1)
	tb.Position = UDim2.new(0.5, -RADIUS - 16, 1, -48)
	tb.Size = UDim2.fromOffset(18, RADIUS * 2)
	tb.BackgroundColor3 = Color3.fromRGB(20, 26, 36)
	tb.BorderSizePixel = 0
	tb.Parent = gui
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0.5, 1)
	fill.Position = UDim2.fromScale(0.5, 1)
	fill.Size = UDim2.new(1, 0, 0, 0)
	fill.BackgroundColor3 = Color3.fromRGB(120, 255, 140)
	fill.BorderSizePixel = 0
	fill.Parent = tb
	self._throttleFill = fill

	-- SAS label (right of the ball).
	local sas = Instance.new("TextLabel")
	sas.AnchorPoint = Vector2.new(0, 1)
	sas.Position = UDim2.new(0.5, RADIUS + 16, 1, -48 - RADIUS + 10)
	sas.Size = UDim2.fromOffset(150, 24)
	sas.BackgroundTransparency = 1
	sas.Font = Enum.Font.Code
	sas.TextSize = 15
	sas.TextXAlignment = Enum.TextXAlignment.Left
	sas.TextColor3 = Color3.fromRGB(120, 200, 255)
	sas.Text = "SAS: Ascent"
	sas.Parent = gui
	self._sasLabel = sas
end

local function place(marker, d, right, up, look)
	local fb = d:Dot(look)
	local x = d:Dot(right)
	local y = d:Dot(up)
	local off
	if fb >= 0 then
		off = Vector2.new(x, -y) * RADIUS
	else
		local v = Vector2.new(x, -y)
		off = (v.Magnitude > 1e-3 and v.Unit or Vector2.new(0, 1)) * RADIUS
	end
	marker.Position = UDim2.new(0.5, off.X, 0.5, off.Y)
	marker.BackgroundTransparency = (fb >= 0) and 0 or 0.65
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

	local v = state.velocity
	local vel = Vector3.new(v.x, v.y, v.z)
	local pro = (vel.Magnitude > 1e-3) and vel.Unit or look

	place(self._mPro, pro, right, up, look)
	place(self._mRetro, -pro, right, up, look)
	place(self._mRadOut, radOut, right, up, look)
	place(self._mRadIn, -radOut, right, up, look)

	self._throttleFill.Size = UDim2.new(1, 0, (info.throttle or 0), 0)
	self._sasLabel.Text = "SAS: " .. tostring(info.sas or "-")
end

return NavballController
