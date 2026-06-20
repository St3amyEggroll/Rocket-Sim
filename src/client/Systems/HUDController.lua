--[[
	HUDController
	Owner of: the flight HUD ScreenGui (orbit readout + vehicle telemetry).

	Shown only in Flight mode (the VAB has its own UI). Reads Orbit.getReadout and
	the vehicle telemetry passed in FlightController.Updated each frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local HUDController = {}

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

local function newPanel(parent, width, anchor, position)
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

local function newRow(parent, order, height, textSize)
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
	local Mode = Registry:Get("GameModeController")

	self:_build(playerGui)
	self._gui.Enabled = (Mode:GetMode() == "Flight")

	Mode.ModeChanged:Connect(function(m)
		self._gui.Enabled = (m == "Flight")
	end)

	Flight:GetUpdatedSignal():Connect(function(state, info)
		if info.mode == "Flight" then
			self:_update(state, info)
		end
	end)
end

function HUDController:_build(parent)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = parent
	self._gui = gui

	local readout = newPanel(gui, 250, Vector2.new(0, 0), UDim2.fromOffset(16, 16))
	local title = newRow(readout, 0, 24, 18)
	title.Text = "[ " .. Config.BODY.name .. " ]"
	title.TextColor3 = Color3.fromRGB(120, 200, 255)

	local L = self._labels
	L.altitude = newRow(readout, 1, 18, 15)
	L.radar = newRow(readout, 2, 18, 15)
	L.speed = newRow(readout, 3, 18, 15)
	L.vspeed = newRow(readout, 4, 18, 15)
	L.apoapsis = newRow(readout, 5, 18, 15)
	L.periapsis = newRow(readout, 6, 18, 15)
	L.ecc = newRow(readout, 7, 18, 15)
	L.period = newRow(readout, 8, 18, 15)

	-- Vehicle panel (bottom-left).
	local veh = newPanel(gui, 250, Vector2.new(0, 1), UDim2.new(0, 16, 1, -16))
	L.statusMode = newRow(veh, 0, 20, 16)
	L.stage = newRow(veh, 1, 18, 15)
	L.fuel = newRow(veh, 2, 18, 15)
	L.stageDV = newRow(veh, 3, 18, 15)
	L.mass = newRow(veh, 4, 18, 15)
	L.throttle = newRow(veh, 5, 18, 15)
	L.thrustMode = newRow(veh, 6, 18, 15)
	L.warp = newRow(veh, 7, 18, 15)

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -16)
	hint.Size = UDim2.fromOffset(1080, 22)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 14
	hint.TextColor3 = Color3.fromRGB(175, 185, 200)
	hint.Text =
		"WASD/QE Steer   Shift/Ctrl Throttle   1-5 SAS Pro/Retro/RadOut/RadIn/Ascent   Space Stage   . / , Warp   M Map   B Build   RMB Look   Wheel Zoom"
	hint.Parent = gui
end

function HUDController:_update(state, info)
	local r = Orbit.getReadout(state, info.mu, info.bodyRadius)
	local L = self._labels

	-- Radar altitude (height above the actual terrain) and vertical speed help
	-- with landing; sea-level altitude/apsides remain relative to the datum.
	local p = state.position
	local rMag = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local radarAlt = rMag - Planet.radiusForSim(p)
	local vertSpeed = 0
	if rMag > 1e-6 then
		local v = state.velocity
		vertSpeed = (v.x * p.x + v.y * p.y + v.z * p.z) / rMag
	end

	L.altitude.Text = "Altitude:  " .. fmt(r.altitude)
	L.radar.Text = "Radar alt: " .. fmt(radarAlt)
	L.speed.Text = "Speed:     " .. fmt(r.speed) .. " st/s"
	L.vspeed.Text = "Vert spd:  " .. fmt(vertSpeed) .. " st/s"
	L.apoapsis.Text = "Apoapsis:  " .. (r.apoapsis == math.huge and "--" or fmt(r.apoapsis))
	L.periapsis.Text = "Periapsis: " .. fmt(r.periapsis)
	L.ecc.Text = "Ecc:       " .. string.format("%.4f", r.eccentricity)
	L.period.Text = "Period:    " .. (r.period == math.huge and "--" or (fmt(r.period) .. " s"))

	local statusColor
	if info.status == "Powered" then
		statusColor = Color3.fromRGB(120, 255, 140)
	elseif info.status == "Crashed" then
		statusColor = Color3.fromRGB(255, 90, 90)
	elseif info.status == "Landed" then
		statusColor = Color3.fromRGB(255, 200, 120)
	else
		statusColor = Color3.fromRGB(120, 200, 255)
	end
	L.statusMode.Text = "* " .. string.upper(info.status)
	L.statusMode.TextColor3 = statusColor

	local t = info.tele
	if t then
		local stageTxt = t.hasEngine and (t.stageIndex .. " / " .. t.stageCount) or ("-- (spent)")
		L.stage.Text = "Stage:     " .. stageTxt
		local fuelPct = math.floor(t.fuelFrac * 100 + 0.5)
		L.fuel.Text = "Fuel:      " .. fuelPct .. "%" .. (t.hasEngine and "" or "  [Space]")
		L.stageDV.Text = "Stage dV:  " .. fmt(t.stageDV)
		L.mass.Text = "Mass:      " .. string.format("%.2f", t.mass)
	end

	L.throttle.Text = "Throttle:  " .. math.floor(info.throttle * 100 + 0.5) .. "%"
	L.thrustMode.Text = "SAS:       " .. tostring(info.sas)
	L.warp.Text = "Warp:      " .. (info.warp or 1) .. "x"
end

return HUDController
