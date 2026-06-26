--[[
	StagingController
	Owner of: the KSP-style staging stack (bottom-right).

	A vertical STACK of stage cards, top -> bottom in firing order, linked by a connector spine
	down the left. Each card has a round stage-number badge, a fuel gauge per booster section
	feeding that stage, and an icon chip for every actuator (engine / decoupler / chute) on it.

	In the VAB it is editable:
	  * DRAG a chip onto another card to move that part to that stage; drop it on "+ Add stage"
	    to push it into a fresh stage.
	  * DRAG a card by its grip (⠿) to reorder the whole firing sequence.
	  * "+ Add stage" appends an empty stage (capped at the vehicle's max).

	In flight it is read-only and live: fired stages dim, the next stage (what Space fires) is
	outlined, and a STAGE button fires it. Fuel gauges animate every frame.

	Performance: the cards are only rebuilt when the staging CONTENTS change (a content signature
	guards it), not on every VehicleController.Changed; and part thumbnails (ViewportFrames) are
	cloned from a per-part cached template instead of being rebuilt from geometry each time.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local PartPreview = require(Shared:WaitForChild("PartPreview"))

local StagingController = {}

local PANEL = Color3.fromRGB(18, 21, 29)
local CARD = Color3.fromRGB(32, 37, 48)
local CARD_FIRED = Color3.fromRGB(22, 25, 32)
local SPINE = Color3.fromRGB(70, 80, 96)
local ACCENT = Color3.fromRGB(120, 200, 255)
local NEXT = Color3.fromRGB(245, 205, 90)
local LIVE = Color3.fromRGB(110, 220, 130)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(120, 128, 140)
local CHIP_BG = Color3.fromRGB(14, 16, 22)

local CARD_H = 48

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 6)
	c.Parent = inst
end

local function inRect(m, frame)
	if not frame or not frame.Visible then
		return false
	end
	local p, s = frame.AbsolutePosition, frame.AbsoluteSize
	return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
end

function StagingController:Init()
	self._rows = {}
	self._fuelBars = {}
	self._editable = true
	self._chipDrag = nil
	self._cardDrag = nil
	self._thumbTmpl = {} -- [partId] = template ViewportFrame (cloned per chip)
	self._sig = nil
end

function StagingController:Start()
	self._vehicle = Registry:Get("VehicleController")
	self._mode = Registry:Get("GameModeController")
	self._input = Registry:Get("InputController")

	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))
	self:_applyMode(self._mode:GetMode())

	self._vehicle.Changed:Connect(function()
		self:_render()
	end)
	self._mode.ModeChanged:Connect(function(m)
		self:_applyMode(m)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if self._chipDrag then
				self:_moveGhost(self._chipDrag)
			elseif self._cardDrag then
				self:_moveGhost(self._cardDrag)
				self:_updateDropLine()
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self._chipDrag then
				self:_dropChip()
			elseif self._cardDrag then
				self:_dropCard()
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		self:_updateFuel()
	end)

	self:_render(true)
end

-- A part thumbnail (ViewportFrame), cloned from a cached per-part template.
function StagingController:_thumb(def)
	local tmpl = self._thumbTmpl[def.id]
	if not tmpl then
		tmpl = PartPreview.thumbnail(def)
		tmpl.Parent = nil
		self._thumbTmpl[def.id] = tmpl
	end
	return tmpl:Clone()
end

function StagingController:_updateFuel()
	if not self._gui or not self._gui.Enabled then
		return
	end
	for _, b in ipairs(self._fuelBars) do
		local frac = self._vehicle:GetSectionFuelFrac(b.sec)
		b.fill.Size = UDim2.new(1, 0, frac, 0)
		b.fill.BackgroundColor3 = (frac > 0.22) and LIVE or Color3.fromRGB(228, 116, 58)
	end
end

function StagingController:_build(parentGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimStaging"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 55
	gui.Parent = parentGui
	self._gui = gui

	-- Bottom-right panel; the stack grows upward from above the action button.
	local pane = Instance.new("Frame")
	pane.AnchorPoint = Vector2.new(1, 1)
	pane.Position = UDim2.new(1, -16, 1, -16)
	pane.Size = UDim2.new(0, 300, 0.64, 0)
	pane.BackgroundColor3 = PANEL
	pane.BackgroundTransparency = 0.1
	pane.BorderSizePixel = 0
	pane.Parent = gui
	corner(pane, 12)
	local pstroke = Instance.new("UIStroke")
	pstroke.Color = Color3.fromRGB(44, 52, 64)
	pstroke.Thickness = 1
	pstroke.Parent = pane
	self._pane = pane

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -24, 0, 20)
	header.Position = UDim2.fromOffset(14, 10)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = ACCENT
	header.Text = "STAGING"
	header.Parent = pane

	self._hint = Instance.new("TextLabel")
	self._hint.Size = UDim2.new(1, -24, 0, 14)
	self._hint.Position = UDim2.fromOffset(14, 30)
	self._hint.BackgroundTransparency = 1
	self._hint.Font = Enum.Font.Code
	self._hint.TextSize = 11
	self._hint.TextXAlignment = Enum.TextXAlignment.Left
	self._hint.TextColor3 = DIM
	self._hint.Text = "drag chips • ⠿ drag a card to reorder"
	self._hint.Parent = pane

	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(10, 48)
	scroller.Size = UDim2.new(1, -20, 1, -94)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scroller.Parent = pane
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroller
	self._list = scroller

	-- Bottom action: "+ Add stage" (VAB) / "STAGE ⏵" (flight).
	local action = Instance.new("TextButton")
	action.AnchorPoint = Vector2.new(0.5, 1)
	action.Position = UDim2.new(0.5, 0, 1, -10)
	action.Size = UDim2.new(1, -20, 0, 34)
	action.BackgroundColor3 = CARD
	action.BorderSizePixel = 0
	action.Font = Enum.Font.GothamBold
	action.TextSize = 14
	action.TextColor3 = TEXT
	action.Parent = pane
	corner(action, 8)
	self._action = action
	action.Activated:Connect(function()
		if self._editable then
			self._vehicle:AddStage()
		else
			self._input:GetStageSignal():Fire()
		end
	end)

	-- Insertion line shown while dragging a card to reorder.
	local dropLine = Instance.new("Frame")
	dropLine.Size = UDim2.new(1, -8, 0, 3)
	dropLine.BackgroundColor3 = ACCENT
	dropLine.BorderSizePixel = 0
	dropLine.ZIndex = 40
	dropLine.Visible = false
	dropLine.Parent = scroller
	corner(dropLine, 2)
	self._dropLine = dropLine
end

function StagingController:_applyMode(m)
	local vab = (m == "VAB")
	self._editable = vab
	if self._gui then
		self._gui.Enabled = (m == "VAB" or m == "Flight")
	end
	if self._hint then
		self._hint.Text = vab and "drag chips • ⠿ drag a card to reorder" or "Space fires the next stage"
	end
	if self._action then
		self._action.Text = vab and "+ Add stage" or "STAGE ⏵"
		self._action.BackgroundColor3 = vab and CARD or Color3.fromRGB(60, 120, 80)
	end
	self:_cancelDrag()
	self:_render(true)
end

-- A compact signature of what the stack should look like, so we only rebuild (recreating
-- ViewportFrame chips) when the staging contents / mode / current stage actually change.
function StagingController:_signature(contents, stageCount, current)
	local out = { self._editable and "E" or "F", stageCount, current, #self._vehicle:GetParts() }
	for s = 1, stageCount do
		out[#out + 1] = "|" .. s .. ":"
		for _, c in ipairs(contents[s] or {}) do
			out[#out + 1] = c.id .. "x" .. c.count .. ";"
		end
		for _, sec in ipairs(self._vehicle:GetStageSections(s)) do
			out[#out + 1] = "g" .. sec
		end
	end
	return table.concat(out)
end

-- Rebuild the stage cards from the current design (skipped when nothing visible changed).
function StagingController:_render(force)
	if not self._list then
		return
	end

	local contents = self._vehicle:GetStageContents()
	local stageCount = self._vehicle:GetStageCount()
	local current = self._vehicle:GetCurrentStageIndex()

	local sig = self:_signature(contents, stageCount, current)
	if not force and sig == self._sig then
		return
	end
	self._sig = sig

	for _, row in ipairs(self._rows) do
		row.frame:Destroy()
	end
	self._rows = {}
	self._fuelBars = {} -- fills are children of the rows, destroyed with them

	for s = 1, stageCount do
		self:_makeCard(s, contents[s] or {}, current, stageCount)
	end

	-- "+ Add stage" reflects the stage cap while building.
	if self._editable and self._action then
		local canAdd = self._vehicle:CanAddStage()
		self._action.Active = canAdd
		self._action.AutoButtonColor = canAdd
		self._action.Text = canAdd and "+ Add stage" or ("Max " .. self._vehicle:GetMaxStages() .. " stages")
		self._action.BackgroundColor3 = canAdd and CARD or Color3.fromRGB(46, 38, 38)
	end
end

function StagingController:_makeCard(stage, chips, current, stageCount)
	local flying = not self._editable
	local fired = flying and (stage < current)
	local isLive = flying and (stage == current)
	local isNext = flying and (stage == current + 1)

	local card = Instance.new("Frame")
	card.Name = "Stage" .. stage
	card.Size = UDim2.new(1, 0, 0, CARD_H)
	card.BackgroundColor3 = fired and CARD_FIRED or CARD
	card.BorderSizePixel = 0
	card.LayoutOrder = stage
	card.ClipsDescendants = false
	card.Parent = self._list
	corner(card, 9)
	if isNext or isLive then
		local stroke = Instance.new("UIStroke")
		stroke.Color = isLive and LIVE or NEXT
		stroke.Thickness = 2
		stroke.Parent = card
	end

	-- Connector spine: a stub rising into the gap above, chaining this badge to the previous.
	if stage > 1 then
		local link = Instance.new("Frame")
		link.Size = UDim2.fromOffset(3, 11)
		link.Position = UDim2.fromOffset(20, -9)
		link.BackgroundColor3 = SPINE
		link.BorderSizePixel = 0
		link.ZIndex = 0
		link.Parent = card
	end

	-- Round stage-number badge.
	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromOffset(30, 30)
	badge.Position = UDim2.fromOffset(6, (CARD_H - 30) / 2)
	badge.BackgroundColor3 = fired and DIM or (isLive and LIVE or (isNext and NEXT or ACCENT))
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.TextSize = 15
	badge.TextColor3 = Color3.fromRGB(16, 20, 26)
	badge.Text = tostring(stage)
	badge.Parent = card
	corner(badge, 15)

	-- Grip handle (VAB): press to drag-reorder the whole card.
	local rightPad = 8
	if self._editable then
		local grip = Instance.new("TextButton")
		grip.AnchorPoint = Vector2.new(1, 0.5)
		grip.Position = UDim2.new(1, -6, 0.5, 0)
		grip.Size = UDim2.fromOffset(22, 34)
		grip.BackgroundColor3 = Color3.fromRGB(42, 48, 60)
		grip.BorderSizePixel = 0
		grip.Font = Enum.Font.GothamBold
		grip.TextSize = 16
		grip.TextColor3 = DIM
		grip.AutoButtonColor = true
		grip.Text = "⠿"
		grip.Parent = card
		corner(grip, 5)
		grip.MouseButton1Down:Connect(function()
			self:_beginCardDrag(stage)
		end)
		rightPad = 34
	end

	-- Content holder: fuel gauges then actuator chips, laid out horizontally.
	local holderX = 44
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(holderX, 0)
	holder.Size = UDim2.new(1, -(holderX + rightPad), 1, 0)
	holder.Parent = card
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.VerticalAlignment = Enum.VerticalAlignment.Center
	hl.Padding = UDim.new(0, 4)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = holder

	local order = 0
	-- One thin fuel gauge per booster section feeding this stage's engines.
	for _, sec in ipairs(self._vehicle:GetStageSections(stage)) do
		order += 1
		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromOffset(5, 32)
		bg.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
		bg.BorderSizePixel = 0
		bg.LayoutOrder = order
		bg.Parent = holder
		corner(bg, 2)
		local fill = Instance.new("Frame")
		fill.AnchorPoint = Vector2.new(0.5, 1)
		fill.Position = UDim2.new(0.5, 0, 1, 0)
		fill.Size = UDim2.new(1, 0, self._vehicle:GetSectionFuelFrac(sec), 0)
		fill.BackgroundColor3 = LIVE
		fill.BorderSizePixel = 0
		fill.Parent = bg
		corner(fill, 2)
		self._fuelBars[#self._fuelBars + 1] = { fill = fill, sec = sec }
	end

	if #chips == 0 then
		order += 1
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.fromOffset(120, CARD_H)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Code
		empty.TextSize = 11
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.TextColor3 = DIM
		empty.Text = fired and "(fired)" or "(empty)"
		empty.LayoutOrder = order
		empty.Parent = holder
	end

	for _, chip in ipairs(chips) do
		order += 1
		self:_makeChip(holder, chip, fired, order)
	end

	self._rows[#self._rows + 1] = { frame = card, stage = stage }
end

-- A staging chip: a small 3D part icon, with a symmetry-count badge for grouped copies.
function StagingController:_makeChip(holder, chip, fired, order)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(34, 32)
	b.BackgroundColor3 = CHIP_BG
	b.BorderSizePixel = 0
	b.Text = ""
	b.AutoButtonColor = self._editable
	b.LayoutOrder = order
	b.Parent = holder
	corner(b, 6)

	local vf = self:_thumb(chip.def)
	vf.Size = UDim2.new(1, -2, 1, -2)
	vf.Position = UDim2.fromOffset(1, 1)
	vf.Active = false -- let the button receive the click
	vf.Parent = b

	if fired then
		local shade = Instance.new("Frame")
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		shade.BackgroundTransparency = 0.55
		shade.BorderSizePixel = 0
		shade.ZIndex = 2
		shade.Parent = b
		corner(shade, 6)
	end

	if chip.count and chip.count > 1 then
		local badge = Instance.new("TextLabel")
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, 3, 0, -4)
		badge.Size = UDim2.fromOffset(16, 16)
		badge.BackgroundColor3 = LIVE
		badge.BorderSizePixel = 0
		badge.Font = Enum.Font.GothamBold
		badge.TextSize = 11
		badge.TextColor3 = Color3.fromRGB(16, 20, 16)
		badge.Text = tostring(chip.count)
		badge.ZIndex = 4
		badge.Parent = b
		corner(badge, 8)
	end

	if self._editable then
		b.MouseButton1Down:Connect(function()
			self:_beginChipDrag(chip)
		end)
	end
end

-- ---- chip dragging (moves a part / symmetry group to another stage) ----

function StagingController:_beginChipDrag(chip)
	self:_cancelDrag()
	local ghost = Instance.new("Frame")
	ghost.Size = UDim2.fromOffset(38, 36)
	ghost.BackgroundColor3 = CHIP_BG
	ghost.BackgroundTransparency = 0.05
	ghost.BorderSizePixel = 0
	ghost.ZIndex = 50
	ghost.Parent = self._gui
	corner(ghost, 7)
	local vf = self:_thumb(chip.def)
	vf.Size = UDim2.new(1, -2, 1, -2)
	vf.Position = UDim2.fromOffset(1, 1)
	vf.ZIndex = 51
	vf.Active = false
	vf.Parent = ghost
	self._chipDrag = { indices = chip.indices, ghost = ghost }
	self:_moveGhost(self._chipDrag)
end

-- ---- card dragging (reorders the whole firing sequence) ----

function StagingController:_beginCardDrag(stage)
	self:_cancelDrag()
	local ghost = Instance.new("TextLabel")
	ghost.Size = UDim2.fromOffset(34, 34)
	ghost.BackgroundColor3 = ACCENT
	ghost.BorderSizePixel = 0
	ghost.Font = Enum.Font.GothamBold
	ghost.TextSize = 16
	ghost.TextColor3 = Color3.fromRGB(16, 20, 26)
	ghost.Text = tostring(stage)
	ghost.ZIndex = 50
	ghost.Parent = self._gui
	corner(ghost, 17)
	self._cardDrag = { stage = stage, ghost = ghost }
	self:_moveGhost(self._cardDrag)
	self:_updateDropLine()
end

function StagingController:_moveGhost(d)
	if not d or not d.ghost then
		return
	end
	local m = UserInputService:GetMouseLocation()
	d.ghost.Position = UDim2.fromOffset(m.X - 18, m.Y - 16)
end

-- The insertion position (1..N) the dragged card would drop into, by cursor Y vs the other cards.
function StagingController:_dropIndex()
	local m = UserInputService:GetMouseLocation()
	local from = self._cardDrag and self._cardDrag.stage
	local pos = 1
	for _, row in ipairs(self._rows) do
		if row.stage ~= from then
			local center = row.frame.AbsolutePosition.Y + row.frame.AbsoluteSize.Y * 0.5
			if m.Y > center then
				pos += 1
			end
		end
	end
	return pos
end

function StagingController:_updateDropLine()
	if not self._cardDrag or not self._dropLine then
		return
	end
	local m = UserInputService:GetMouseLocation()
	if not inRect(m, self._list) then
		self._dropLine.Visible = false
		return
	end
	-- The line is a canvas child, so position it in canvas space (cards are placed by AbsolutePosition).
	local listTop = self._list.AbsolutePosition.Y
	local scroll = self._list.CanvasPosition.Y
	local lineY
	for _, row in ipairs(self._rows) do
		local f = row.frame
		local center = f.AbsolutePosition.Y + f.AbsoluteSize.Y * 0.5
		if m.Y < center then
			lineY = (f.AbsolutePosition.Y - listTop + scroll) - 5
			break
		end
	end
	if not lineY and #self._rows > 0 then
		local f = self._rows[#self._rows].frame
		lineY = (f.AbsolutePosition.Y - listTop + scroll) + f.AbsoluteSize.Y + 2
	end
	self._dropLine.Position = UDim2.new(0, 4, 0, lineY or 0)
	self._dropLine.Visible = true
end

function StagingController:_dropCard()
	local d = self._cardDrag
	if not d then
		return
	end
	local m = UserInputService:GetMouseLocation()
	local over = inRect(m, self._list)
	local target = self:_dropIndex()
	self:_cancelDrag()
	if over then
		self._vehicle:ReorderStage(d.stage, target)
	end
end

function StagingController:_dropChip()
	local d = self._chipDrag
	if not d then
		return
	end
	local m = UserInputService:GetMouseLocation()
	local target = nil
	for _, row in ipairs(self._rows) do
		if inRect(m, row.frame) then
			target = row.stage
			break
		end
	end
	if not target and inRect(m, self._action) then
		target = math.min(self._vehicle:GetStageCount() + 1, self._vehicle:GetMaxStages())
	end
	self:_cancelDrag()
	if target then
		self._vehicle:SetPartsStage(d.indices, target)
	end
end

function StagingController:_cancelDrag()
	if self._chipDrag then
		if self._chipDrag.ghost then
			self._chipDrag.ghost:Destroy()
		end
		self._chipDrag = nil
	end
	if self._cardDrag then
		if self._cardDrag.ghost then
			self._cardDrag.ghost:Destroy()
		end
		self._cardDrag = nil
	end
	if self._dropLine then
		self._dropLine.Visible = false
	end
end

return StagingController
