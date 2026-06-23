--[[
	StagingController
	Owner of: the KSP-style staging panel (right edge).

	The panel lists the firing sequence top -> bottom as a column of stage rows; each row
	holds a chip for every actuator (engine / decoupler) assigned to that stage.

	In the VAB it is editable:
	  * DRAG a chip onto another row to move that part to that stage; drag it onto the
	    "+ New stage" drop zone to push it into a fresh stage.
	  * ▲ / ▼ on a row reorder the firing sequence.
	  * "+ Add stage" appends an empty stage.

	In flight it is read-only and live: already-fired stages dim out and the next stage
	(what Space fires) is highlighted; a STAGE button fires it.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local StagingController = {}

local PANEL = Color3.fromRGB(20, 23, 31)
local ROW = Color3.fromRGB(30, 34, 44)
local ROW_FIRED = Color3.fromRGB(24, 27, 34)
local ACCENT = Color3.fromRGB(120, 200, 255)
local NEXT = Color3.fromRGB(245, 205, 90)
local LIVE = Color3.fromRGB(110, 220, 130)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(120, 128, 140)
local ENGINE_C = Color3.fromRGB(222, 132, 70)
local DEC_C = Color3.fromRGB(132, 140, 152)

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
		if self._chipDrag and input.UserInputType == Enum.UserInputType.MouseMovement then
			self:_moveGhost()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and self._chipDrag then
			self:_dropChip()
		end
	end)

	-- Live fuel gauges: keep the bar fills in sync with each section's remaining fuel.
	RunService.RenderStepped:Connect(function()
		self:_updateFuel()
	end)

	self:_render()
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

	local pane = Instance.new("Frame")
	pane.AnchorPoint = Vector2.new(1, 0)
	pane.Position = UDim2.new(1, -16, 0, 534)
	pane.Size = UDim2.new(0, 314, 1, -624)
	pane.BackgroundColor3 = PANEL
	pane.BackgroundTransparency = 0.08
	pane.BorderSizePixel = 0
	pane.Parent = gui
	corner(pane, 10)
	self._pane = pane

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -24, 0, 20)
	header.Position = UDim2.fromOffset(14, 8)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = ACCENT
	header.Text = "STAGING"
	header.Parent = pane

	self._hint = Instance.new("TextLabel")
	self._hint.Size = UDim2.new(1, -24, 0, 14)
	self._hint.Position = UDim2.fromOffset(14, 28)
	self._hint.BackgroundTransparency = 1
	self._hint.Font = Enum.Font.Code
	self._hint.TextSize = 11
	self._hint.TextXAlignment = Enum.TextXAlignment.Left
	self._hint.TextColor3 = DIM
	self._hint.Text = "drag parts • ▲▼ reorder"
	self._hint.Parent = pane

	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(10, 46)
	scroller.Size = UDim2.new(1, -20, 1, -94)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = pane
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = scroller
	self._list = scroller

	-- Bottom action button: "+ Add stage" (VAB) / "STAGE ⏵" (flight).
	local action = Instance.new("TextButton")
	action.AnchorPoint = Vector2.new(0.5, 1)
	action.Position = UDim2.new(0.5, 0, 1, -10)
	action.Size = UDim2.new(1, -20, 0, 32)
	action.BackgroundColor3 = ROW
	action.BorderSizePixel = 0
	action.Font = Enum.Font.GothamBold
	action.TextSize = 13
	action.TextColor3 = TEXT
	action.Parent = pane
	corner(action, 6)
	self._action = action
	action.Activated:Connect(function()
		if self._editable then
			self._vehicle:AddStage()
		else
			self._input:GetStageSignal():Fire()
		end
	end)
end

function StagingController:_applyMode(m)
	local vab = (m == "VAB")
	self._editable = vab
	if self._gui then
		self._gui.Enabled = (m == "VAB" or m == "Flight")
	end
	if self._hint then
		self._hint.Text = vab and "drag parts • ▲▼ reorder" or "Space fires the next stage"
	end
	if self._action then
		self._action.Text = vab and "+ Add stage" or "STAGE ⏵"
		self._action.BackgroundColor3 = vab and ROW or Color3.fromRGB(60, 120, 80)
	end
	self:_cancelDrag()
	self:_render()
end

-- Rebuild the stage rows from the current design.
function StagingController:_render()
	if not self._list then
		return
	end
	for _, row in ipairs(self._rows) do
		row.frame:Destroy()
	end
	self._rows = {}
	self._fuelBars = {} -- bar fills are children of the rows, destroyed with them

	local contents = self._vehicle:GetStageContents()
	local stageCount = self._vehicle:GetStageCount()
	local current = self._vehicle:GetCurrentStageIndex()

	for s = 1, stageCount do
		self:_makeRow(s, contents[s] or {}, current, stageCount)
	end
end

function StagingController:_makeRow(stage, chips, current, stageCount)
	local flying = not self._editable
	local fired = flying and (stage < current) -- already triggered and gone by
	local isLive = flying and (stage == current) -- most recently triggered (burning)
	local isNext = flying and (stage == current + 1) -- what Space fires next

	local row = Instance.new("Frame")
	row.Name = "Stage" .. stage
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundColor3 = fired and ROW_FIRED or ROW
	row.BorderSizePixel = 0
	row.LayoutOrder = stage
	row.Parent = self._list
	corner(row, 6)
	if isNext or isLive then
		local stroke = Instance.new("UIStroke")
		stroke.Color = isLive and LIVE or NEXT
		stroke.Thickness = 2
		stroke.Parent = row
	end

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromOffset(26, 26)
	badge.Position = UDim2.fromOffset(6, 7)
	badge.BackgroundColor3 = fired and DIM or (isLive and LIVE or (isNext and NEXT or ACCENT))
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.TextSize = 13
	badge.TextColor3 = Color3.fromRGB(18, 20, 26)
	badge.Text = tostring(stage)
	badge.Parent = row
	corner(badge, 5)

	-- Reorder controls (VAB only), pinned right.
	local rightPad = 6
	if self._editable then
		local function arrow(txt, dx, targetStage)
			local b = Instance.new("TextButton")
			b.Size = UDim2.fromOffset(20, 26)
			b.AnchorPoint = Vector2.new(1, 0)
			b.Position = UDim2.new(1, dx, 0, 7)
			b.BackgroundColor3 = Color3.fromRGB(44, 49, 60)
			b.BorderSizePixel = 0
			b.Font = Enum.Font.GothamBold
			b.TextSize = 12
			b.TextColor3 = TEXT
			b.Text = txt
			b.Parent = row
			corner(b, 4)
			b.Activated:Connect(function()
				self._vehicle:SwapStages(stage, targetStage)
			end)
			return b
		end
		if stage > 1 then
			arrow("▲", -6, stage - 1)
		end
		if stage < stageCount then
			arrow("▼", -28, stage + 1)
		end
		rightPad = 56
	end

	-- Fuel gauges: one thin vertical bar per fuel section feeding this stage's engines
	-- (each booster drains its own), pinned just right of the stage badge.
	local barX = 36
	for _, sec in ipairs(self._vehicle:GetStageSections(stage)) do
		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromOffset(5, 30)
		bg.Position = UDim2.fromOffset(barX, 5)
		bg.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
		bg.BorderSizePixel = 0
		bg.Parent = row
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
		barX += 7
	end

	local holderX = barX + 2
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromOffset(holderX, 0)
	holder.Size = UDim2.new(1, -(holderX + rightPad), 1, 0)
	holder.Parent = row
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.VerticalAlignment = Enum.VerticalAlignment.Center
	hl.Padding = UDim.new(0, 4)
	hl.Parent = holder

	if #chips == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 1, 0)
		empty.BackgroundTransparency = 1
		empty.Font = Enum.Font.Code
		empty.TextSize = 11
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.TextColor3 = DIM
		empty.Text = fired and "(fired)" or "(empty)"
		empty.Parent = holder
	end

	for _, chip in ipairs(chips) do
		self:_makeChip(holder, chip, fired)
	end

	self._rows[#self._rows + 1] = { frame = row, stage = stage }
end

function StagingController:_chipLabel(chip)
	if chip.kind == "engine" then
		return "E"
	elseif chip.def.radial then
		return "R"
	end
	return "D"
end

function StagingController:_makeChip(holder, chip, fired)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(30, 28)
	b.BackgroundColor3 = fired and DIM or (chip.kind == "engine" and ENGINE_C or DEC_C)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.fromRGB(20, 22, 28)
	b.Text = self:_chipLabel(chip)
	b.AutoButtonColor = self._editable
	b.Parent = holder
	corner(b, 5)
	if self._editable then
		b.MouseButton1Down:Connect(function()
			self:_beginDrag(chip)
		end)
	end
end

-- ---- chip dragging ----

function StagingController:_beginDrag(chip)
	self:_cancelDrag()
	local ghost = Instance.new("TextLabel")
	ghost.Size = UDim2.fromOffset(34, 30)
	ghost.BackgroundColor3 = chip.kind == "engine" and ENGINE_C or DEC_C
	ghost.BackgroundTransparency = 0.1
	ghost.BorderSizePixel = 0
	ghost.Font = Enum.Font.GothamBold
	ghost.TextSize = 15
	ghost.TextColor3 = Color3.fromRGB(20, 22, 28)
	ghost.Text = self:_chipLabel(chip)
	ghost.ZIndex = 50
	ghost.Parent = self._gui
	corner(ghost, 6)
	self._chipDrag = { index = chip.index, ghost = ghost }
	self:_moveGhost()
end

function StagingController:_moveGhost()
	local d = self._chipDrag
	if not d then
		return
	end
	local m = UserInputService:GetMouseLocation()
	d.ghost.Position = UDim2.fromOffset(m.X - 17, m.Y - 15)
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
		target = self._vehicle:GetStageCount() + 1 -- dropped on "+ Add stage": new stage
	end
	self:_cancelDrag()
	if target then
		self._vehicle:SetPartStage(d.index, target)
	end
end

function StagingController:_cancelDrag()
	if self._chipDrag then
		if self._chipDrag.ghost then
			self._chipDrag.ghost:Destroy()
		end
		self._chipDrag = nil
	end
end

return StagingController
