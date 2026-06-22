--[[
	VABController
	Owner of: the Vehicle Assembly Building UI (shown only in VAB mode).

	KSP-style layout:
	  Left   = parts palette with category tabs (Pods / Fuel / Engines / Struct);
	           click a part card to add it on top of the stack.
	  Middle = the rocket stack (top -> bottom), each row colour-coded with a stage
	           badge; click a row to remove that part.
	  Right  = live stats: total ΔV, mass, launch TWR, and per-stage ΔV.
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
local PANEL = Color3.fromRGB(20, 23, 31)
local ROW = Color3.fromRGB(30, 34, 44)
local ACCENT = Color3.fromRGB(120, 200, 255)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)

-- Category display order + look (KSP-ish names and colours).
local CATS = {
	{ id = "command", label = "Pods", color = Color3.fromRGB(90, 150, 230) },
	{ id = "fuel", label = "Fuel", color = Color3.fromRGB(200, 205, 215) },
	{ id = "engine", label = "Engines", color = Color3.fromRGB(222, 132, 70) },
	{ id = "structure", label = "Struct", color = Color3.fromRGB(132, 140, 152) },
}
local CAT_COLOR = {}
for _, c in ipairs(CATS) do
	CAT_COLOR[c.id] = c.color
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function panel(parent, pos, size, title)
	local f = Instance.new("Frame")
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = PANEL
	f.BackgroundTransparency = 0.1
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 10)

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -24, 0, 22)
	header.Position = UDim2.fromOffset(14, 10)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = ACCENT
	header.Text = title
	header.Parent = f
	return f
end

function VABController:Init()
	self._rows = {}
	self._partCards = {}
	self._tabBtns = {}
	self._activeCat = CATS[1].id
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
	self:_renderPalette()
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

	-- Backdrop so the build screen reads as its own room, not floating over flight.
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(8, 9, 13)
	bg.BackgroundTransparency = 0.4
	bg.BorderSizePixel = 0
	bg.Parent = gui

	-- Centered fixed-size workspace so the panels line up on any resolution.
	local root = Instance.new("Frame")
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 14)
	root.Size = UDim2.fromOffset(948, 528)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 34)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 24
	title.TextColor3 = ACCENT
	title.Text = "VEHICLE ASSEMBLY BUILDING"
	title.Parent = root

	self:_buildPalette(root)
	self:_buildStack(root)
	self:_buildStats(root)
	self:_buildControls(root)
end

function VABController:_buildPalette(root)
	local pane = panel(root, UDim2.fromOffset(0, 46), UDim2.fromOffset(284, 408), "PARTS")

	-- Category tabs.
	local tabs = Instance.new("Frame")
	tabs.Position = UDim2.fromOffset(12, 38)
	tabs.Size = UDim2.new(1, -24, 0, 30)
	tabs.BackgroundTransparency = 1
	tabs.Parent = pane
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.Padding = UDim.new(0, 4)
	tl.Parent = tabs

	for _, cat in ipairs(CATS) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.25, -3, 1, 0)
		b.BackgroundColor3 = ROW
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.TextColor3 = DIM
		b.Text = cat.label
		b.Parent = tabs
		corner(b, 6)
		b.Activated:Connect(function()
			self._activeCat = cat.id
			self:_renderPalette()
		end)
		self._tabBtns[cat.id] = b
	end

	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(12, 74)
	scroller.Size = UDim2.new(1, -24, 1, -86)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = pane
	local pl = Instance.new("UIListLayout")
	pl.Padding = UDim.new(0, 6)
	pl.Parent = scroller
	self._paletteList = scroller
end

function VABController:_renderPalette()
	-- Highlight the active tab.
	for id, b in pairs(self._tabBtns) do
		local active = (id == self._activeCat)
		b.BackgroundColor3 = active and CAT_COLOR[id] or ROW
		b.TextColor3 = active and Color3.fromRGB(20, 22, 28) or DIM
	end

	for _, card in ipairs(self._partCards) do
		card:Destroy()
	end
	self._partCards = {}

	for _, id in ipairs(Catalog.order) do
		local def = Catalog.get(id)
		if def.category == self._activeCat then
			self:_addPartCard(def, id)
		end
	end
end

function VABController:_addPartCard(def, id)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 52)
	b.BackgroundColor3 = ROW
	b.BorderSizePixel = 0
	b.Font = Enum.Font.Gotham
	b.TextSize = 13
	b.TextColor3 = TEXT
	b.TextXAlignment = Enum.TextXAlignment.Left
	b.Text = ""
	b.Parent = self._paletteList
	corner(b, 6)

	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(0, 5, 1, -10)
	stripe.Position = UDim2.fromOffset(6, 5)
	stripe.BackgroundColor3 = CAT_COLOR[def.category] or DIM
	stripe.BorderSizePixel = 0
	stripe.Parent = b
	corner(stripe, 3)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -52, 0, 20)
	name.Position = UDim2.fromOffset(18, 7)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = TEXT
	name.Text = def.name
	name.Parent = b

	local detail
	if def.category == "engine" then
		detail = string.format("thrust %d   ve %d", def.thrust, def.exhaustVelocity)
	elseif def.category == "fuel" then
		detail = string.format("fuel %.1f   mass %.2f", def.fuel, def.mass)
	else
		detail = string.format("mass %.2f", def.mass)
	end
	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, -52, 0, 16)
	sub.Position = UDim2.fromOffset(18, 28)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Code
	sub.TextSize = 12
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextColor3 = DIM
	sub.Text = detail
	sub.Parent = b

	local plus = Instance.new("TextLabel")
	plus.AnchorPoint = Vector2.new(1, 0.5)
	plus.Position = UDim2.new(1, -10, 0.5, 0)
	plus.Size = UDim2.fromOffset(24, 24)
	plus.BackgroundTransparency = 1
	plus.Font = Enum.Font.GothamBold
	plus.TextSize = 22
	plus.TextColor3 = ACCENT
	plus.Text = "+"
	plus.Parent = b

	b.Activated:Connect(function()
		self._vehicle:AddPart(id)
	end)
	table.insert(self._partCards, b)
end

function VABController:_buildStack(root)
	local pane = panel(root, UDim2.fromOffset(296, 46), UDim2.fromOffset(330, 408), "YOUR ROCKET  (top -> bottom)")
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(12, 40)
	scroller.Size = UDim2.new(1, -24, 1, -52)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = pane
	local sl = Instance.new("UIListLayout")
	sl.Padding = UDim.new(0, 5)
	sl.Parent = scroller
	self._stackList = scroller

	self._emptyHint = Instance.new("TextLabel")
	self._emptyHint.Size = UDim2.new(1, -24, 0, 60)
	self._emptyHint.Position = UDim2.fromOffset(12, 56)
	self._emptyHint.BackgroundTransparency = 1
	self._emptyHint.Font = Enum.Font.Gotham
	self._emptyHint.TextSize = 14
	self._emptyHint.TextWrapped = true
	self._emptyHint.TextColor3 = DIM
	self._emptyHint.Text = "Empty. Pick parts on the left -- start with an engine at the bottom, add tanks, then a pod on top."
	self._emptyHint.Parent = pane
end

function VABController:_buildStats(root)
	local pane = panel(root, UDim2.fromOffset(638, 46), UDim2.fromOffset(310, 408), "STATS")

	-- Headline delta-v.
	self._dvBig = Instance.new("TextLabel")
	self._dvBig.Position = UDim2.fromOffset(14, 40)
	self._dvBig.Size = UDim2.new(1, -28, 0, 46)
	self._dvBig.BackgroundTransparency = 1
	self._dvBig.Font = Enum.Font.GothamBold
	self._dvBig.TextSize = 34
	self._dvBig.TextXAlignment = Enum.TextXAlignment.Left
	self._dvBig.TextColor3 = TEXT
	self._dvBig.Text = "0 dV"
	self._dvBig.Parent = pane

	local sub = Instance.new("TextLabel")
	sub.Position = UDim2.fromOffset(14, 84)
	sub.Size = UDim2.new(1, -28, 0, 16)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Code
	sub.TextSize = 12
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextColor3 = DIM
	sub.Text = "total delta-v (studs/s)"
	sub.Parent = pane

	self._statsLabel = Instance.new("TextLabel")
	self._statsLabel.Position = UDim2.fromOffset(14, 112)
	self._statsLabel.Size = UDim2.new(1, -28, 1, -124)
	self._statsLabel.BackgroundTransparency = 1
	self._statsLabel.Font = Enum.Font.Code
	self._statsLabel.TextSize = 14
	self._statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._statsLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._statsLabel.TextColor3 = TEXT
	self._statsLabel.Text = ""
	self._statsLabel.Parent = pane
end

function VABController:_buildControls(root)
	local launch = Instance.new("TextButton")
	launch.AnchorPoint = Vector2.new(0, 1)
	launch.Position = UDim2.new(0, 0, 1, 0)
	launch.Size = UDim2.fromOffset(330, 56)
	launch.BackgroundColor3 = Color3.fromRGB(60, 170, 90)
	launch.BorderSizePixel = 0
	launch.Font = Enum.Font.GothamBold
	launch.TextSize = 22
	launch.TextColor3 = Color3.fromRGB(255, 255, 255)
	launch.Text = "LAUNCH"
	launch.Parent = root
	corner(launch, 10)
	self._launchBtn = launch
	launch.Activated:Connect(function()
		self._mode:SetMode("Flight")
	end)

	local clear = Instance.new("TextButton")
	clear.AnchorPoint = Vector2.new(0, 1)
	clear.Position = UDim2.new(0, 344, 1, 0)
	clear.Size = UDim2.fromOffset(150, 56)
	clear.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	clear.BorderSizePixel = 0
	clear.Font = Enum.Font.GothamBold
	clear.TextSize = 16
	clear.TextColor3 = Color3.fromRGB(255, 255, 255)
	clear.Text = "CLEAR"
	clear.Parent = root
	corner(clear, 10)
	clear.Activated:Connect(function()
		self._vehicle:Clear()
	end)

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, 0, 1, -16)
	hint.Size = UDim2.fromOffset(420, 24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 13
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextColor3 = DIM
	hint.Text = "Click a part to add on top  |  click a stack row to remove  |  B toggles build / flight"
	hint.Parent = root
end

function VABController:_refresh()
	-- Rebuild the stack list (shown top -> bottom; design is bottom -> top).
	for _, row in ipairs(self._rows) do
		row:Destroy()
	end
	self._rows = {}

	local design = self._vehicle:GetDesign()
	local stats = self._vehicle:GetStats()
	self._emptyHint.Visible = (#design == 0)

	for displayPos = #design, 1, -1 do
		local def = design[displayPos]
		local stage = stats.stageOfPart[displayPos] or 0
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, 0, 0, 34)
		row.BackgroundColor3 = ROW
		row.BorderSizePixel = 0
		row.Font = Enum.Font.Gotham
		row.TextSize = 13
		row.AutoButtonColor = true
		row.Text = ""
		row.LayoutOrder = #design - displayPos
		row.Parent = self._stackList
		corner(row, 6)

		local stripe = Instance.new("Frame")
		stripe.Size = UDim2.new(0, 5, 1, -10)
		stripe.Position = UDim2.fromOffset(6, 5)
		stripe.BackgroundColor3 = def.color or DIM
		stripe.BorderSizePixel = 0
		stripe.Parent = row
		corner(stripe, 3)

		local name = Instance.new("TextLabel")
		name.Size = UDim2.new(1, -110, 1, 0)
		name.Position = UDim2.fromOffset(18, 0)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.Gotham
		name.TextSize = 14
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = TEXT
		name.Text = def.name
		name.Parent = row

		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -58, 0.5, 0)
		badge.Size = UDim2.fromOffset(44, 20)
		badge.BackgroundColor3 = (stage > 0) and Color3.fromRGB(44, 50, 64) or Color3.fromRGB(34, 38, 48)
		badge.Font = Enum.Font.GothamBold
		badge.TextSize = 11
		badge.TextColor3 = (stage > 0) and ACCENT or DIM
		badge.Text = (stage > 0) and ("STG " .. stage) or "PAY"
		badge.Parent = row
		corner(badge, 5)

		local rm = Instance.new("TextLabel")
		rm.AnchorPoint = Vector2.new(1, 0.5)
		rm.Position = UDim2.new(1, -10, 0.5, 0)
		rm.Size = UDim2.fromOffset(40, 20)
		rm.BackgroundTransparency = 1
		rm.Font = Enum.Font.Code
		rm.TextSize = 12
		rm.TextColor3 = Color3.fromRGB(220, 120, 120)
		rm.Text = "remove"
		rm.Parent = row

		row.Activated:Connect(function()
			self._vehicle:RemovePart(displayPos)
		end)
		table.insert(self._rows, row)
	end

	-- Stats.
	self._dvBig.Text = string.format("%.0f dV", stats.totalDeltaV)

	local lines = {}
	lines[#lines + 1] = string.format("Mass        %.2f t", stats.totalMass)
	lines[#lines + 1] = string.format("Launch TWR  %.2f", stats.launchTWR)
	lines[#lines + 1] = string.format("Stages      %d", stats.stageCount)
	lines[#lines + 1] = ""
	if stats.stageCount > 0 then
		lines[#lines + 1] = "Per stage (fires 1 first):"
		for k = 1, stats.stageCount do
			lines[#lines + 1] = string.format("  stage %d   %5.0f dV", k, stats.stages[k].deltaV)
		end
	end
	if stats.stageCount == 0 then
		lines[#lines + 1] = "! No engine - add one!"
	elseif stats.launchTWR < 1 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "! TWR < 1: it won't lift off"
		lines[#lines + 1] = "   the ground (fine in orbit)."
	end
	self._statsLabel.Text = table.concat(lines, "\n")

	-- Disable launch with no engine.
	local ready = stats.stageCount > 0
	self._launchBtn.BackgroundColor3 = ready and Color3.fromRGB(60, 170, 90) or Color3.fromRGB(60, 70, 64)
	self._launchBtn.Text = ready and "LAUNCH  ▶" or "ADD AN ENGINE"
	self._launchBtn.Active = ready
	self._launchBtn.AutoButtonColor = ready
end

return VABController
