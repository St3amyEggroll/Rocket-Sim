--[[
	TrackingController
	The Tracking Station (an in-game area, like Research): a roster of every craft you've left in
	orbit, with its body + orbit summary, and per-vessel actions -- Target it for rendezvous,
	Recover it (refund some science + free the slot), or Terminate it.

	Gated to GameMode "Tracking" (the nav bar's Tracking tab). Vessels mirror the server's State
	push; actions go back over ReplicatedStorage.GameRemotes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local TrackingController = {}

local BG = Color3.fromRGB(14, 18, 24)
local ROW = Color3.fromRGB(30, 36, 46)
local ACCENT = Color3.fromRGB(120, 200, 255)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)
local GREEN = Color3.fromRGB(60, 170, 90)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function bodyInfo(bodyId)
	if bodyId == "moon" then
		return Config.MOON.mu, Config.MOON.radius, "Mun"
	elseif bodyId == "sun" then
		return Config.SUN.mu, Config.SUN.radius, "Sol"
	end
	return Config.BODY.mu, Config.BODY.radius, "Terra"
end

local function fmt(n)
	local a = math.abs(n)
	if a >= 1e6 then
		return string.format("%.1fMm", n / 1e6)
	elseif a >= 1e3 then
		return string.format("%.1fkm", n / 1e3)
	end
	return string.format("%.0fm", n)
end

function TrackingController:Init()
	self._vessels = {}
end

function TrackingController:Start()
	self._mode = Registry:Get("GameModeController")
	self._vesselCtrl = Registry:Get("VesselController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._delEv = remotes:WaitForChild("DeleteVessel")
		self._recoverEv = remotes:WaitForChild("RecoverVessel")
		self._stateEv = remotes:WaitForChild("State")
		self._stateEv.OnClientEvent:Connect(function(state)
			if type(state) == "table" then
				self._vessels = state.vessels or {}
				if self._gui and self._gui.Enabled then
					self:_rebuild()
				end
			end
		end)
	end

	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))
	self._mode.ModeChanged:Connect(function(m)
		self._gui.Enabled = (m == "Tracking")
		if m == "Tracking" then
			self:_rebuild()
		end
	end)
	self._gui.Enabled = (self._mode:GetMode() == "Tracking")
end

function TrackingController:_build(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TrackingStation"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 56
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
	backdrop.BackgroundTransparency = 0.2
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0, 560, 0.82, 0)
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	corner(panel, 12)
	panel.Parent = gui

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(18, 12)
	title.Size = UDim2.fromOffset(360, 26)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = "TRACKING STATION"
	title.Parent = panel

	self._empty = Instance.new("TextLabel")
	self._empty.AnchorPoint = Vector2.new(0.5, 0.5)
	self._empty.Position = UDim2.fromScale(0.5, 0.5)
	self._empty.Size = UDim2.fromOffset(420, 40)
	self._empty.BackgroundTransparency = 1
	self._empty.Font = Enum.Font.Gotham
	self._empty.TextSize = 15
	self._empty.TextColor3 = DIM
	self._empty.Text = "No vessels in orbit. Build a craft with a docking port and use\n\"Leave in Orbit\" from the flight menu."
	self._empty.Visible = false
	self._empty.Parent = panel

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(14, 48)
	list.Size = UDim2.new(1, -28, 1, -100)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	self._list = list

	local back = Instance.new("TextButton")
	back.AnchorPoint = Vector2.new(0.5, 1)
	back.Position = UDim2.new(0.5, 0, 1, -12)
	back.Size = UDim2.fromOffset(180, 32)
	back.BackgroundColor3 = ROW
	back.BorderSizePixel = 0
	back.Font = Enum.Font.GothamBold
	back.TextSize = 14
	back.TextColor3 = TEXT
	back.Text = "Back to Build"
	corner(back, 6)
	back.Parent = panel
	back.Activated:Connect(function()
		self._mode:SetMode("VAB")
	end)

	self._rows = {}
end

local function smallBtn(parent, text, color, x)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, x, 0.5, 0)
	b.Size = UDim2.fromOffset(78, 30)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Text = text
	corner(b, 6)
	b.Parent = parent
	return b
end

function TrackingController:_rebuild()
	for _, r in ipairs(self._rows) do
		r:Destroy()
	end
	self._rows = {}

	local n = #self._vessels
	self._empty.Visible = (n == 0)

	for i, v in ipairs(self._vessels) do
		local mu, radius, bodyName = bodyInfo(v.bodyId)
		local ro
		if v.pos and v.vel then
			ro = Orbit.getReadout(
				{ position = Orbit.vec(v.pos.x, v.pos.y, v.pos.z), velocity = Orbit.vec(v.vel.x, v.vel.y, v.vel.z) },
				mu,
				radius
			)
		end

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 58)
		row.BackgroundColor3 = ROW
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		corner(row, 8)
		row.Parent = self._list
		self._rows[#self._rows + 1] = row

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(14, 8)
		name.Size = UDim2.new(1, -270, 0, 20)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBold
		name.TextSize = 15
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = TEXT
		name.Text = (v.name or ("Vessel " .. i)) .. "   (" .. bodyName .. ")"
		name.Parent = row

		local orbitTxt = Instance.new("TextLabel")
		orbitTxt.Position = UDim2.fromOffset(14, 30)
		orbitTxt.Size = UDim2.new(1, -270, 0, 18)
		orbitTxt.BackgroundTransparency = 1
		orbitTxt.Font = Enum.Font.Code
		orbitTxt.TextSize = 12
		orbitTxt.TextXAlignment = Enum.TextXAlignment.Left
		orbitTxt.TextColor3 = DIM
		if ro then
			local ap = (ro.apoapsis == math.huge) and "--" or fmt(ro.apoapsis - radius)
			orbitTxt.Text = ("Ap %s   Pe %s"):format(ap, fmt(ro.periapsis - radius))
		else
			orbitTxt.Text = "orbit unknown"
		end
		orbitTxt.Parent = row

		local idx = i
		smallBtn(row, "Target", Color3.fromRGB(60, 110, 160), -178).Activated:Connect(function()
			if self._vesselCtrl then
				self._vesselCtrl:SetTargetIndex(idx)
			end
		end)
		smallBtn(row, "Recover", GREEN, -94).Activated:Connect(function()
			if self._recoverEv then
				self._recoverEv:FireServer(idx)
			end
		end)
		smallBtn(row, "Terminate", Color3.fromRGB(150, 64, 64), -10).Activated:Connect(function()
			if self._delEv then
				self._delEv:FireServer(idx)
			end
		end)
	end
end

return TrackingController
