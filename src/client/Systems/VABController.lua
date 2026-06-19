--[[
	VABController
	Owner of: the Vehicle Assembly Building UI (shown only in VAB mode).

	Left  = parts palette (click to add on top of the stack).
	Middle = the current rocket (top -> bottom); click a row to remove it.
	Right = live stats (mass, stages, total delta-v, launch TWR).
	Bottom = LAUNCH / CLEAR.

	It only drives the design through VehicleController and the mode through
	GameModeController; it owns no flight state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))

local VABController = {}

local DARK = Color3.fromRGB(14, 16, 22)
local ACCENT = Color3.fromRGB(120, 200, 255)

local function panel(parent, pos, size, title)
	local f = Instance.new("Frame")
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = DARK
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = f

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -16, 0, 24)
	header.Position = UDim2.fromOffset(12, 8)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 15
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = ACCENT
	header.Text = title
	header.Parent = f
	return f
end

function VABController:Init()
	self._rows = {}
end

function VABController:Start()
	self._vehicle = Registry:Get("VehicleController")
	self._mode = Registry:Get("GameModeController")
	local player = Players.LocalPlayer

	self:_build(player:WaitForChild("PlayerGui"))

	self._vehicle.Changed:Connect(function()
		self:_refresh()
	end)
	self._mode.ModeChanged:Connect(function(m)
		self._gui.Enabled = (m == "VAB")
	end)
	self._gui.Enabled = (self._mode:GetMode() == "VAB")
	self:_refresh()
end

function VABController:_build(parentGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimVAB"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = parentGui
	self._gui = gui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 36)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = ACCENT
	title.Text = "VEHICLE ASSEMBLY"
	title.Parent = gui

	-- Palette (left).
	local palette = panel(gui, UDim2.fromOffset(16, 56), UDim2.fromOffset(250, 360), "PARTS")
	local plist = Instance.new("Frame")
	plist.Position = UDim2.fromOffset(12, 40)
	plist.Size = UDim2.new(1, -24, 1, -52)
	plist.BackgroundTransparency = 1
	plist.Parent = palette
	local pl = Instance.new("UIListLayout")
	pl.Padding = UDim.new(0, 6)
	pl.Parent = plist

	for _, id in ipairs(Catalog.order) do
		local def = Catalog.get(id)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 48)
		b.BackgroundColor3 = Color3.fromRGB(32, 36, 46)
		b.BorderSizePixel = 0
		b.Font = Enum.Font.Gotham
		b.TextSize = 13
		b.TextColor3 = Color3.fromRGB(230, 234, 240)
		b.TextXAlignment = Enum.TextXAlignment.Left
		local detail
		if def.category == "engine" then
			detail = string.format("thrust %d  ve %d", def.thrust, def.exhaustVelocity)
		elseif def.category == "fuel" then
			detail = string.format("fuel %.1f  mass %.2f", def.fuel, def.mass)
		else
			detail = string.format("mass %.2f", def.mass)
		end
		b.Text = "  + " .. def.name .. "\n      " .. detail
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = b
		b.Parent = plist
		b.Activated:Connect(function()
			self._vehicle:AddPart(id)
		end)
	end

	-- Rocket stack (middle).
	local stack = panel(gui, UDim2.fromOffset(282, 56), UDim2.fromOffset(280, 360), "YOUR ROCKET (top -> bottom)")
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(12, 40)
	scroller.Size = UDim2.new(1, -24, 1, -52)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = stack
	local sl = Instance.new("UIListLayout")
	sl.Padding = UDim.new(0, 4)
	sl.Parent = scroller
	self._stackList = scroller

	-- Stats (right).
	local stats = panel(gui, UDim2.fromOffset(578, 56), UDim2.fromOffset(240, 360), "STATS")
	self._statsLabel = Instance.new("TextLabel")
	self._statsLabel.Position = UDim2.fromOffset(12, 40)
	self._statsLabel.Size = UDim2.new(1, -24, 1, -52)
	self._statsLabel.BackgroundTransparency = 1
	self._statsLabel.Font = Enum.Font.Code
	self._statsLabel.TextSize = 15
	self._statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._statsLabel.TextColor3 = Color3.fromRGB(225, 230, 238)
	self._statsLabel.Text = ""
	self._statsLabel.Parent = stats

	-- Launch / Clear (bottom).
	local launch = Instance.new("TextButton")
	launch.AnchorPoint = Vector2.new(0, 1)
	launch.Position = UDim2.new(0, 16, 1, -16)
	launch.Size = UDim2.fromOffset(220, 52)
	launch.BackgroundColor3 = Color3.fromRGB(60, 170, 90)
	launch.BorderSizePixel = 0
	launch.Font = Enum.Font.GothamBold
	launch.TextSize = 20
	launch.TextColor3 = Color3.fromRGB(255, 255, 255)
	launch.Text = "LAUNCH  >"
	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(0, 8)
	lc.Parent = launch
	launch.Parent = gui
	launch.Activated:Connect(function()
		self._mode:SetMode("Flight")
	end)

	local clear = Instance.new("TextButton")
	clear.AnchorPoint = Vector2.new(0, 1)
	clear.Position = UDim2.new(0, 248, 1, -16)
	clear.Size = UDim2.fromOffset(120, 52)
	clear.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	clear.BorderSizePixel = 0
	clear.Font = Enum.Font.GothamBold
	clear.TextSize = 16
	clear.TextColor3 = Color3.fromRGB(255, 255, 255)
	clear.Text = "CLEAR"
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 8)
	cc.Parent = clear
	clear.Parent = gui
	clear.Activated:Connect(function()
		self._vehicle:Clear()
	end)

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -16, 1, -16)
	hint.Size = UDim2.fromOffset(560, 24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 14
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextColor3 = Color3.fromRGB(175, 185, 200)
	hint.Text = "Click parts to stack (bottom->top).  Click a row to remove.  B toggles build / flight."
	hint.Parent = gui
end

function VABController:_refresh()
	-- Rebuild the stack list (shown top -> bottom; design is bottom -> top).
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	local design = self._vehicle:GetDesign()
	for displayPos = #design, 1, -1 do
		local def = design[displayPos]
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, 0, 0, 30)
		row.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
		row.BorderSizePixel = 0
		row.Font = Enum.Font.Gotham
		row.TextSize = 13
		row.TextColor3 = Color3.fromRGB(230, 234, 240)
		row.Text = "  " .. def.name .. "   (x to remove)"
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.LayoutOrder = #design - displayPos
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = row
		row.Parent = self._stackList
		row.Activated:Connect(function()
			self._vehicle:RemovePart(displayPos)
		end)
		table.insert(self._rows, row)
	end

	-- Stats.
	local s = self._vehicle:GetStats()
	local lines = {}
	lines[#lines + 1] = string.format("Total mass:   %.2f", s.totalMass)
	lines[#lines + 1] = string.format("Stages:       %d", s.stageCount)
	lines[#lines + 1] = string.format("Total dV:     %.0f st/s", s.totalDeltaV)
	lines[#lines + 1] = string.format("Launch TWR:   %.2f", s.launchTWR)
	lines[#lines + 1] = ""
	for k = 1, s.stageCount do
		lines[#lines + 1] = string.format("  stage %d dV: %.0f", k, s.stages[k].deltaV)
	end
	if s.stageCount == 0 then
		lines[#lines + 1] = "(no engine - add one!)"
	elseif s.launchTWR < 1 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "TWR < 1: weak liftoff,"
		lines[#lines + 1] = "but fine for orbit burns."
	end
	self._statsLabel.Text = table.concat(lines, "\n")
end

return VABController
