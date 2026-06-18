--[[
	HUDController
	Owner of: the flight HUD ScreenGui.

	Reads Orbit.getReadout each frame (via FlightController.Updated) and shows the
	live orbital state plus throttle / thrust mode / status. Pure read-side: it
	owns no sim state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local HUDController = {}

-- Compact number formatting (k / M suffixes; handles infinity & NaN).
local function fmt(n: number): string
	if n == math.huge then
		return "inf"
	elseif n == -math.huge then
		return "-inf"
	elseif n ~= n then
		return "--"
	end
	local a = math.abs(n)
	if a >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif a >= 1e3 then
		return string.format("%.2fk", n / 1e3)
	end
	return string.format("%.1f", n)
end

local function newPanel(parent: Instance, width: number, anchor: Vector2, position: UDim2): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = anchor
	f.Position = position
	f.Size = UDim2.new(0, width, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
	f.BackgroundTransparency = 0.25
	f.BorderSizePixel = 0
	f.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = f

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = f

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = f

	return f
end

local function newRow(parent: Instance, order: number, height: number, textSize: number): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.LayoutOrder = order
	lbl.Size = UDim2.new(1, 0, 0, height)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Code
	lbl.TextSize = textSize
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = Color3.fromRGB(220, 230, 240)
	lbl.Text = ""
	lbl.Parent = parent
	return lbl
end

function HUDController:Init()
	self._labels = {}
end

function HUDController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local Flight = Registry:Get("FlightController")

	self:_build(playerGui)

	-- Prime with the current state, then track every frame.
	self:_update(Flight:GetState(), {
		throttle = 0,
		thrustMode = "Prograde",
		status = "Coasting",
		mu = Flight:GetMu(),
		bodyRadius = Flight:GetBodyRadius(),
	})

	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_update(state, info)
	end)
end

function HUDController:_build(parent: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent

	-- Orbit readout (top-left).
	local readout = newPanel(gui, 260, Vector2.new(0, 0), UDim2.fromOffset(16, 16))

	local title = newRow(readout, 0, 24, 18)
	title.Text = "[ " .. Config.BODY.name .. " ]"
	title.TextColor3 = Color3.fromRGB(120, 200, 255)

	local L = self._labels
	L.altitude = newRow(readout, 1, 18, 15)
	L.speed = newRow(readout, 2, 18, 15)
	L.apoapsis = newRow(readout, 3, 18, 15)
	L.periapsis = newRow(readout, 4, 18, 15)
	L.ecc = newRow(readout, 5, 18, 15)
	L.period = newRow(readout, 6, 18, 15)
	L.energy = newRow(readout, 7, 18, 15)

	-- Status (bottom-left).
	local status = newPanel(gui, 260, Vector2.new(0, 1), UDim2.new(0, 16, 1, -16))
	L.statusMode = newRow(status, 1, 20, 16)
	L.throttle = newRow(status, 2, 20, 16)
	L.thrustMode = newRow(status, 3, 20, 16)

	-- Controls hint (bottom-centre).
	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -16)
	hint.Size = UDim2.fromOffset(980, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(175, 185, 200)
	hint.Text =
		"Shift/Ctrl Throttle   Z Full / X Cut   1 Prograde  2 Retrograde  3 RadialOut  4 RadialIn   RMB+Drag Orbit   Wheel Zoom"
	hint.Parent = gui
end

function HUDController:_update(state, info)
	local r = Orbit.getReadout(state, info.mu, info.bodyRadius)
	local L = self._labels

	L.altitude.Text = "Altitude:  " .. fmt(r.altitude)
	L.speed.Text = "Speed:     " .. fmt(r.speed) .. " st/s"
	L.apoapsis.Text = "Apoapsis:  " .. (r.apoapsis == math.huge and "--" or fmt(r.apoapsis))
	L.periapsis.Text = "Periapsis: " .. fmt(r.periapsis)
	L.ecc.Text = "Ecc:       " .. string.format("%.4f", r.eccentricity)
	L.period.Text = "Period:    " .. (r.period == math.huge and "--" or (fmt(r.period) .. " s"))
	L.energy.Text = "Energy:    " .. string.format("%.1f", r.specificEnergy)

	local statusColor
	if info.status == "Powered" then
		statusColor = Color3.fromRGB(120, 255, 140)
	elseif info.status == "Landed" then
		statusColor = Color3.fromRGB(255, 200, 120)
	else
		statusColor = Color3.fromRGB(120, 200, 255)
	end

	L.statusMode.Text = "* " .. string.upper(info.status)
	L.statusMode.TextColor3 = statusColor
	L.throttle.Text = "Throttle:  " .. math.floor(info.throttle * 100 + 0.5) .. "%"
	L.thrustMode.Text = "Thrust:    " .. info.thrustMode
end

return HUDController
