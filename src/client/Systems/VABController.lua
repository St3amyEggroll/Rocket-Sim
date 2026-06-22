--[[
	VABController
	Owner of: the Vehicle Assembly Building UI (shown only in VAB mode).

	KSP-style DRAG-AND-DROP assembly:
	  Left   = parts palette (category tabs). DRAG a part onto the rocket to add it.
	  Centre = the rocket, built bottom -> top. The first part dropped is the anchor;
	           each further part snaps in where you drop it (a guide line shows where).
	           Click a part to select it.
	  Right  = the selected part's stats, plus the whole-craft summary + a Remove.
	  Bottom = LAUNCH / CLEAR.

	It drives the design through VehicleController (InsertPart / RemovePart / Clear)
	and the mode through GameModeController; it owns no flight state.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
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
local PX_PER_STUD = 7 -- vertical scale of the rocket diagram

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
	self._partCards = {}
	self._tabBtns = {}
	self._blocks = {}
	self._activeCat = CATS[1].id
	self._selected = nil
	self._drag = nil
	self._dropIndex = nil
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
		if m ~= "VAB" then
			self:_cancelDrag()
		end
	end)
	self._gui.Enabled = (self._mode:GetMode() == "VAB")

	UserInputService.InputChanged:Connect(function(input)
		self:_onInputChanged(input)
	end)
	UserInputService.InputEnded:Connect(function(input)
		self:_onInputEnded(input)
	end)

	self:_renderPalette()
	self:_refresh()
end

-- ---------------------------------------------------------------- build ----

function VABController:_build(parentGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimVAB"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = parentGui
	self._gui = gui

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(8, 9, 13)
	bg.BackgroundTransparency = 0.35
	bg.BorderSizePixel = 0
	bg.Parent = gui

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
	self:_buildCanvas(root)
	self:_buildRight(root)
	self:_buildControls(root)

	-- Drop guide line (where a dragged part will snap in) + drag layer live on the gui.
	local line = Instance.new("Frame")
	line.Name = "DropLine"
	line.BackgroundColor3 = ACCENT
	line.BorderSizePixel = 0
	line.ZIndex = 40
	line.Visible = false
	line.Parent = gui
	corner(line, 2)
	self._dropLine = line
end

function VABController:_buildPalette(root)
	local pane = panel(root, UDim2.fromOffset(0, 46), UDim2.fromOffset(250, 408), "PARTS  (drag onto rocket)")

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
	b.Size = UDim2.new(1, 0, 0, 50)
	b.BackgroundColor3 = ROW
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
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
	name.Size = UDim2.new(1, -24, 0, 20)
	name.Position = UDim2.fromOffset(18, 6)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = TEXT
	name.Text = def.name
	name.Parent = b

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -24, 0, 16)
	hint.Position = UDim2.fromOffset(18, 27)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = DIM
	hint.Text = "drag to add"
	hint.Parent = b

	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			self:_startDrag(id, input.Position)
		end
	end)
	table.insert(self._partCards, b)
end

function VABController:_buildCanvas(root)
	local pane = panel(root, UDim2.fromOffset(262, 46), UDim2.fromOffset(360, 408), "ROCKET  (bottom -> top)")
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(10, 38)
	scroller.Size = UDim2.new(1, -20, 1, -50)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = pane
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 2)
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroller
	self._canvas = scroller

	local hint = Instance.new("TextLabel")
	hint.Name = "EmptyHint"
	hint.AnchorPoint = Vector2.new(0.5, 0.5)
	hint.Position = UDim2.fromScale(0.5, 0.5)
	hint.Size = UDim2.new(1, -40, 0, 80)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 15
	hint.TextWrapped = true
	hint.TextColor3 = DIM
	hint.Text = "Drag parts here from the left.\nStart with an engine (the anchor), then add tanks and a pod on top."
	hint.Parent = pane
	self._emptyHint = hint
end

function VABController:_buildRight(root)
	local pane = panel(root, UDim2.fromOffset(634, 46), UDim2.fromOffset(314, 408), "PART")

	self._partLabel = Instance.new("TextLabel")
	self._partLabel.Position = UDim2.fromOffset(14, 40)
	self._partLabel.Size = UDim2.new(1, -28, 0, 150)
	self._partLabel.BackgroundTransparency = 1
	self._partLabel.Font = Enum.Font.Code
	self._partLabel.TextSize = 14
	self._partLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._partLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._partLabel.TextColor3 = TEXT
	self._partLabel.Text = ""
	self._partLabel.Parent = pane

	self._removeBtn = Instance.new("TextButton")
	self._removeBtn.Position = UDim2.fromOffset(14, 196)
	self._removeBtn.Size = UDim2.new(1, -28, 0, 32)
	self._removeBtn.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	self._removeBtn.BorderSizePixel = 0
	self._removeBtn.Font = Enum.Font.GothamBold
	self._removeBtn.TextSize = 14
	self._removeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	self._removeBtn.Text = "Remove Part"
	self._removeBtn.Visible = false
	self._removeBtn.Parent = pane
	corner(self._removeBtn, 6)
	self._removeBtn.Activated:Connect(function()
		if self._selected then
			self._vehicle:RemovePart(self._selected)
			self._selected = nil
		end
	end)

	local div = Instance.new("Frame")
	div.Position = UDim2.fromOffset(14, 240)
	div.Size = UDim2.new(1, -28, 0, 1)
	div.BackgroundColor3 = Color3.fromRGB(60, 66, 80)
	div.BorderSizePixel = 0
	div.Parent = pane

	local craftTitle = Instance.new("TextLabel")
	craftTitle.Position = UDim2.fromOffset(14, 250)
	craftTitle.Size = UDim2.new(1, -28, 0, 18)
	craftTitle.BackgroundTransparency = 1
	craftTitle.Font = Enum.Font.GothamBold
	craftTitle.TextSize = 13
	craftTitle.TextXAlignment = Enum.TextXAlignment.Left
	craftTitle.TextColor3 = ACCENT
	craftTitle.Text = "CRAFT"
	craftTitle.Parent = pane

	self._craftLabel = Instance.new("TextLabel")
	self._craftLabel.Position = UDim2.fromOffset(14, 272)
	self._craftLabel.Size = UDim2.new(1, -28, 1, -284)
	self._craftLabel.BackgroundTransparency = 1
	self._craftLabel.Font = Enum.Font.Code
	self._craftLabel.TextSize = 14
	self._craftLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._craftLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._craftLabel.TextColor3 = TEXT
	self._craftLabel.Text = ""
	self._craftLabel.Parent = pane
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
		self._selected = nil
		self._vehicle:Clear()
	end)
end

-- ------------------------------------------------------------- assembly ----

function VABController:_blockSize(def)
	local h = math.max(def.height or 0, 1.7) * PX_PER_STUD
	local w = math.clamp((def.radius or 3) * 16, 34, 300)
	return w, h
end

function VABController:_refresh()
	local design = self._vehicle:GetDesign()
	local stats = self._vehicle:GetStats()
	local n = #design

	if self._selected and not design[self._selected] then
		self._selected = nil
	end
	self._emptyHint.Visible = (n == 0)

	for _, b in ipairs(self._blocks) do
		b.frame:Destroy()
	end
	self._blocks = {}

	for index = 1, n do
		local def = design[index]
		local w, h = self:_blockSize(def)
		local block = Instance.new("TextButton")
		block.Size = UDim2.fromOffset(w, h)
		block.BackgroundColor3 = def.color
		block.AutoButtonColor = false
		block.BorderSizePixel = 0
		block.Text = ""
		block.LayoutOrder = n - index -- index 1 (bottom) sorts last -> bottom of the list
		block.Parent = self._canvas
		corner(block, 5)

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 12
		lbl.TextColor3 = Color3.fromRGB(20, 22, 28)
		lbl.TextStrokeTransparency = 0.6
		lbl.Text = def.name
		lbl.Parent = block

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = ACCENT
		stroke.Enabled = (index == self._selected)
		stroke.Parent = block

		local thisIndex = index
		block.Activated:Connect(function()
			self:_select(thisIndex)
		end)
		table.insert(self._blocks, { index = index, frame = block, stroke = stroke })
	end

	self:_updatePartPanel()

	-- Craft summary.
	local prof = self._vehicle:GetRotProfile()
	local lines = {}
	lines[#lines + 1] = string.format("dV total   %.0f", stats.totalDeltaV)
	lines[#lines + 1] = string.format("Mass       %.2f t", stats.totalMass)
	lines[#lines + 1] = string.format("Launch TWR %.2f", stats.launchTWR)
	lines[#lines + 1] = string.format("Stages     %d", stats.stageCount)
	if prof.mass > 0 then
		local stable = prof.margin > 0
		lines[#lines + 1] = "Stability  " .. (stable and "STABLE" or "UNSTABLE")
	end
	if stats.stageCount == 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "! Add an engine to launch."
	end
	self._craftLabel.Text = table.concat(lines, "\n")

	local ready = stats.stageCount > 0
	self._launchBtn.BackgroundColor3 = ready and Color3.fromRGB(60, 170, 90) or Color3.fromRGB(60, 70, 64)
	self._launchBtn.Text = ready and "LAUNCH" or "ADD AN ENGINE"
	self._launchBtn.Active = ready
	self._launchBtn.AutoButtonColor = ready
end

function VABController:_select(index)
	self._selected = index
	for _, b in ipairs(self._blocks) do
		b.stroke.Enabled = (b.index == index)
	end
	self:_updatePartPanel()
end

function VABController:_updatePartPanel()
	local design = self._vehicle:GetDesign()
	local def = self._selected and design[self._selected]
	if not def then
		self._partLabel.Text = "Click a part to inspect it."
		self._partLabel.TextColor3 = DIM
		self._removeBtn.Visible = false
		return
	end
	self._partLabel.TextColor3 = TEXT
	self._removeBtn.Visible = true
	local lines = {}
	lines[#lines + 1] = def.name
	lines[#lines + 1] = "category  " .. def.category
	lines[#lines + 1] = string.format("mass      %.2f t", def.mass or 0)
	lines[#lines + 1] = string.format("size      %.1f x %.1f", (def.radius or 0) * 2, def.height or 0)
	lines[#lines + 1] = string.format("drag      %.2f", def.drag or 0)
	if def.fuel then
		lines[#lines + 1] = string.format("fuel      %.1f", def.fuel)
	end
	if def.category == "engine" then
		lines[#lines + 1] = string.format("thrust    %d", def.thrust or 0)
		lines[#lines + 1] = string.format("exhaust v %d", def.exhaustVelocity or 0)
	end
	self._partLabel.Text = table.concat(lines, "\n")
end

-- ----------------------------------------------------------------- drag ----

function VABController:_startDrag(id, pos)
	self:_cancelDrag()
	local def = Catalog.get(id)
	if not def then
		return
	end
	local ghost = Instance.new("Frame")
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Size = UDim2.fromOffset(130, 30)
	ghost.BackgroundColor3 = def.color
	ghost.BackgroundTransparency = 0.2
	ghost.BorderSizePixel = 0
	ghost.ZIndex = 50
	ghost.Position = UDim2.fromOffset(pos.X, pos.Y)
	ghost.Parent = self._gui
	corner(ghost, 6)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 13
	lbl.TextColor3 = Color3.fromRGB(20, 22, 28)
	lbl.ZIndex = 51
	lbl.Text = def.name
	lbl.Parent = ghost

	self._drag = { id = id, ghost = ghost }
	self._dropIndex = nil
end

function VABController:_cancelDrag()
	if self._drag then
		self._drag.ghost:Destroy()
		self._drag = nil
	end
	self._dropIndex = nil
	if self._dropLine then
		self._dropLine.Visible = false
	end
end

local function over(frame, x, y)
	local ap, as = frame.AbsolutePosition, frame.AbsoluteSize
	return x >= ap.X and x <= ap.X + as.X and y >= ap.Y and y <= ap.Y + as.Y
end

function VABController:_computeDrop(mouseY)
	local n = #self._vehicle:GetDesign()
	if n == 0 then
		return 1
	end
	local list = table.clone(self._blocks)
	table.sort(list, function(a, b)
		return a.frame.AbsolutePosition.Y < b.frame.AbsolutePosition.Y
	end)
	local slot = 0
	for _, b in ipairs(list) do
		local mid = b.frame.AbsolutePosition.Y + b.frame.AbsoluteSize.Y * 0.5
		if mouseY > mid then
			slot += 1
		else
			break
		end
	end
	return math.clamp(n + 1 - slot, 1, n + 1)
end

function VABController:_onInputChanged(input)
	if not self._drag then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local pos = input.Position
	self._drag.ghost.Position = UDim2.fromOffset(pos.X, pos.Y)

	if over(self._canvas, pos.X, pos.Y) then
		self._dropIndex = self:_computeDrop(pos.Y)
		local ap, as = self._canvas.AbsolutePosition, self._canvas.AbsoluteSize
		self._dropLine.Visible = true
		self._dropLine.Position = UDim2.fromOffset(ap.X + 8, pos.Y - 1)
		self._dropLine.Size = UDim2.fromOffset(as.X - 16, 3)
	else
		self._dropIndex = nil
		self._dropLine.Visible = false
	end
end

function VABController:_onInputEnded(input)
	if not self._drag then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local id = self._drag.id
	local dropIndex = self._dropIndex
	self:_cancelDrag()
	if dropIndex then
		self._selected = dropIndex
		self._vehicle:InsertPart(dropIndex, id)
	end
end

return VABController
