--[[
	TechController (client)
	Mirrors the player's tech progress from the server, detects flight milestones (reporting
	them to earn science), tells the VAB which parts are unlocked (VABController gates the
	palette on this), and shows the tech-tree UI + a science toast.

	Milestones are detected from the flight telemetry and reported once each; the server is
	the authority on science totals + unlocks (and persists them).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))
local TechTree = require(Shared:WaitForChild("TechTree"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))
local PartPreview = require(Shared:WaitForChild("PartPreview"))

local TechController = {}

local BG = Color3.fromRGB(18, 21, 28)
local ROW = Color3.fromRGB(30, 34, 44)
local ACCENT = Color3.fromRGB(120, 200, 255)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)
local GREEN = Color3.fromRGB(60, 170, 90)
local GREY = Color3.fromRGB(60, 66, 76)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
	return inst
end

function TechController:Init()
	self.Changed = Signal.new()
	self._state = { science = 0, unlocked = { basics = true }, milestones = {} }
	self._unlockedParts = TechTree.unlockedParts(self._state.unlocked)
	self._reported = {}
end

function TechController:Start()
	self._mode = Registry:Get("GameModeController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._stateEv = remotes:WaitForChild("State")
		self._reportEv = remotes:WaitForChild("ReportMilestone")
		self._unlockEv = remotes:WaitForChild("UnlockTier")
		self._stateEv.OnClientEvent:Connect(function(state)
			self:_applyState(state)
		end)
		self._stateEv:FireServer() -- request current profile (covers a late client)
	end

	self:_buildUI()
	-- The tech tree lives in its own RESEARCH area (the nav bar's Research tab), not the VAB.
	self._mode.ModeChanged:Connect(function(m)
		self:_setResearchVisible(m == "Research")
	end)
	self:_setResearchVisible(self._mode:GetMode() == "Research")

	Registry:Get("FlightController"):GetUpdatedSignal():Connect(function(state, info)
		self:_checkMilestones(state, info)
	end)
end

function TechController:_applyState(state)
	if type(state) ~= "table" then
		return
	end
	self._state = state
	self._state.unlocked = self._state.unlocked or { basics = true }
	self._state.milestones = self._state.milestones or {}
	self._unlockedParts = TechTree.unlockedParts(self._state.unlocked)
	-- Re-sync the "already reported" set from the server's granted milestones.
	self._reported = {}
	for id in pairs(self._state.milestones) do
		self._reported[id] = true
	end
	self.Changed:Fire()
	self:_refreshTree()
end

function TechController:IsPartUnlocked(partId)
	return self._unlockedParts[partId] == true
end

function TechController:GetScience()
	return self._state.science or 0
end

function TechController:_report(id, label, science)
	if self._reported[id] then
		return
	end
	self._reported[id] = true
	if self._reportEv then
		self._reportEv:FireServer(id)
	end
	self:_toast(("+%d Science  -  %s"):format(science or 0, label or ""))
end

local function reportIf(self, cond, id)
	if cond then
		for _, m in ipairs(TechTree.milestones) do
			if m.id == id then
				self:_report(id, m.label, m.science)
				return
			end
		end
	end
end

function TechController:_checkMilestones(state, info)
	if not info or info.mode ~= "Flight" then
		return
	end
	local bodyId = info.bodyId
	if bodyId == "planet" then
		local p = state.position
		local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		local alt = r - (info.bodyRadius or 0)
		reportIf(self, alt > 5000, "alt5k")
		reportIf(self, alt > 25000, "alt25k")
		reportIf(self, alt > Config.ATMOSPHERE.top, "space")
		-- Stable orbit: periapsis clears the atmosphere (won't reenter).
		local ro = Orbit.getReadout(state, info.mu)
		if ro and ro.periapsis and (ro.periapsis - (info.bodyRadius or 0)) > Config.ATMOSPHERE.top then
			reportIf(self, true, "orbit")
		end
	elseif bodyId == "moon" then
		reportIf(self, true, "munSOI")
		reportIf(self, info.status == "Landed", "munLand")
	elseif bodyId == "sun" then
		reportIf(self, true, "solar")
	end
end

function TechController:_requestUnlock(tierId)
	if self._unlockEv then
		self._unlockEv:FireServer(tierId)
	end
end

-- ------------------------------------------------------------------ UI ----

function TechController:_buildUI()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Toast (always on; milestones happen in flight). A label that fades after a moment.
	local toastGui = Instance.new("ScreenGui")
	toastGui.Name = "TechToast"
	toastGui.ResetOnSpawn = false
	toastGui.IgnoreGuiInset = true
	toastGui.DisplayOrder = 80
	toastGui.Parent = pg
	local toast = Instance.new("TextLabel")
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, 90)
	toast.Size = UDim2.fromOffset(420, 30)
	toast.BackgroundColor3 = BG
	toast.BackgroundTransparency = 0.2
	toast.Font = Enum.Font.GothamBold
	toast.TextSize = 16
	toast.TextColor3 = Color3.fromRGB(150, 235, 170)
	toast.Text = ""
	toast.Visible = false
	corner(toast, 8)
	toast.Parent = toastGui
	self._toastLabel = toast
	self._toastToken = 0

	-- RESEARCH area (its own screen, opened by the nav bar's Research tab -> mode "Research"):
	-- a KSP-style tech-tree GRAPH -- part-icon nodes laid out in columns by tier, each tier
	-- wired back to the previous one with a right-angle bus connector, over a dark backdrop.
	local gui = Instance.new("ScreenGui")
	gui.Name = "ResearchGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 55
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
	backdrop.BackgroundTransparency = 0.15
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.95, 0, 0.9, 0)
	panel.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	corner(panel, 12)
	panel.Parent = gui
	self._panel = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(18, 12)
	title.Size = UDim2.fromOffset(260, 26)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = "RESEARCH"
	title.Parent = panel

	self._sciLabel = Instance.new("TextLabel")
	self._sciLabel.AnchorPoint = Vector2.new(1, 0)
	self._sciLabel.Position = UDim2.new(1, -150, 0, 14)
	self._sciLabel.Size = UDim2.fromOffset(220, 22)
	self._sciLabel.BackgroundTransparency = 1
	self._sciLabel.Font = Enum.Font.GothamBold
	self._sciLabel.TextSize = 16
	self._sciLabel.TextXAlignment = Enum.TextXAlignment.Right
	self._sciLabel.TextColor3 = Color3.fromRGB(150, 235, 170)
	self._sciLabel.Text = "Science: 0"
	self._sciLabel.Parent = panel

	local back = Instance.new("TextButton")
	back.AnchorPoint = Vector2.new(1, 0)
	back.Position = UDim2.new(1, -16, 0, 12)
	back.Size = UDim2.fromOffset(120, 28)
	back.BackgroundColor3 = ROW
	back.BorderSizePixel = 0
	back.Font = Enum.Font.GothamBold
	back.TextSize = 13
	back.TextColor3 = TEXT
	back.Text = "Back to Build"
	corner(back, 6)
	back.Parent = panel
	back.Activated:Connect(function()
		self._mode:SetMode("VAB")
	end)

	-- Scrollable graph canvas (the tree can be wider/taller than the panel).
	local graph = Instance.new("ScrollingFrame")
	graph.Position = UDim2.fromOffset(12, 48)
	graph.Size = UDim2.new(1, -24, 1, -60)
	graph.BackgroundColor3 = Color3.fromRGB(9, 12, 18)
	graph.BackgroundTransparency = 0.2
	graph.BorderSizePixel = 0
	graph.ScrollBarThickness = 6
	graph.ScrollingDirection = Enum.ScrollingDirection.XY
	graph.CanvasSize = UDim2.new()
	corner(graph, 10)
	graph.Parent = panel

	self:_buildGraph(graph)
	self:_refreshTree()
end

-- Lay out the tech tree as a node graph: one column per tier, each part a small icon node,
-- columns wired to the previous tier by a vertical bus + horizontal stubs (KSP style). Stores
-- per-tier node strokes / unlock chips / connector frames so _refreshTree can recolour them.
function TechController:_buildGraph(parent)
	local NODE = 58
	local COL_W = 150
	local ROW_H = 74
	local PAD_X = 46
	local PAD_TOP = 68

	local nTiers = #TechTree.tiers
	local maxRows = 1
	for _, tier in ipairs(TechTree.tiers) do
		maxRows = math.max(maxRows, #tier.parts)
	end
	parent.CanvasSize = UDim2.fromOffset(PAD_X * 2 + (nTiers - 1) * COL_W + NODE, PAD_TOP + maxRows * ROW_H + 30)

	local function colX(i)
		return PAD_X + (i - 1) * COL_W
	end
	local function colStartY(n)
		return PAD_TOP + (maxRows - n) * ROW_H / 2
	end

	-- Node centres per tier (used to wire the connectors).
	local centres = {}
	for i, tier in ipairs(TechTree.tiers) do
		local n = #tier.parts
		local sy, x, cs = colStartY(n), colX(i), {}
		for j = 1, n do
			local y = sy + (j - 1) * ROW_H
			cs[j] = { x = x, y = y, cy = y + NODE / 2 }
		end
		centres[i] = cs
	end

	-- Thin line segment helper (a Frame). Connectors are drawn first so nodes sit on top.
	local function seg(x, y, w, h)
		local f = Instance.new("Frame")
		f.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
		f.Size = UDim2.fromOffset(math.max(2, math.floor(w)), math.max(2, math.floor(h)))
		f.BackgroundColor3 = Color3.fromRGB(48, 60, 54)
		f.BorderSizePixel = 0
		f.ZIndex = 1
		f.Parent = parent
		return f
	end

	self._tierConns = {}
	for i = 2, nTiers do
		local leftRight = colX(i - 1) + NODE -- right edge of the previous column
		local rightLeft = colX(i) -- left edge of this column
		local railX = (leftRight + rightLeft) / 2
		local conns, minY, maxY = {}, math.huge, -math.huge
		for _, c in ipairs(centres[i - 1]) do
			conns[#conns + 1] = seg(leftRight, c.cy - 1, railX - leftRight, 2)
			minY, maxY = math.min(minY, c.cy), math.max(maxY, c.cy)
		end
		for _, c in ipairs(centres[i]) do
			conns[#conns + 1] = seg(railX, c.cy - 1, rightLeft - railX, 2)
			minY, maxY = math.min(minY, c.cy), math.max(maxY, c.cy)
		end
		conns[#conns + 1] = seg(railX - 1, minY, 2, maxY - minY) -- vertical bus
		self._tierConns[i] = conns
	end

	self._tierNodes = {}
	for i, tier in ipairs(TechTree.tiers) do
		local x = colX(i)
		local headerX = x - (COL_W - NODE) / 2

		local hdr = Instance.new("TextLabel")
		hdr.Position = UDim2.fromOffset(headerX, 8)
		hdr.Size = UDim2.fromOffset(COL_W, 18)
		hdr.BackgroundTransparency = 1
		hdr.Font = Enum.Font.GothamBold
		hdr.TextSize = 13
		hdr.TextColor3 = TEXT
		hdr.Text = tier.name
		hdr.ZIndex = 2
		hdr.Parent = parent

		local chip = Instance.new("TextButton")
		chip.Position = UDim2.fromOffset(headerX + (COL_W - 96) / 2, 30)
		chip.Size = UDim2.fromOffset(96, 22)
		chip.BackgroundColor3 = GREY
		chip.BorderSizePixel = 0
		chip.Font = Enum.Font.GothamBold
		chip.TextSize = 12
		chip.TextColor3 = Color3.fromRGB(255, 255, 255)
		chip.Text = "LOCKED"
		chip.ZIndex = 2
		corner(chip, 6)
		chip.Parent = parent
		chip.Activated:Connect(function()
			self:_requestUnlock(tier.id)
		end)

		local strokes = {}
		for j, partId in ipairs(tier.parts) do
			local def = Catalog.get(partId)
			local c = centres[i][j]

			local node = Instance.new("TextButton")
			node.Position = UDim2.fromOffset(c.x, c.y)
			node.Size = UDim2.fromOffset(NODE, NODE)
			node.BackgroundColor3 = Color3.fromRGB(20, 26, 22)
			node.AutoButtonColor = true
			node.BorderSizePixel = 0
			node.Text = ""
			node.ZIndex = 2
			corner(node, 8)
			node.Parent = parent
			node.Activated:Connect(function()
				self:_requestUnlock(tier.id)
			end)

			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 2
			stroke.Color = GREY
			stroke.Parent = node
			strokes[#strokes + 1] = stroke

			if def then
				local thumb = PartPreview.thumbnail(def)
				thumb.Size = UDim2.fromOffset(NODE - 10, NODE - 10)
				thumb.Position = UDim2.fromOffset(5, 5)
				thumb.ZIndex = 3
				thumb.Parent = node
			else
				local lbl = Instance.new("TextLabel")
				lbl.Size = UDim2.fromScale(1, 1)
				lbl.BackgroundTransparency = 1
				lbl.Font = Enum.Font.Code
				lbl.TextSize = 9
				lbl.TextWrapped = true
				lbl.TextColor3 = DIM
				lbl.Text = partId
				lbl.ZIndex = 3
				lbl.Parent = node
			end
		end

		self._tierNodes[i] = { strokes = strokes, chip = chip }
	end
end

function TechController:_setResearchVisible(v)
	if self._gui then
		self._gui.Enabled = v
	end
end

function TechController:_refreshTree()
	if not self._tierNodes then
		return
	end
	local sci = self:GetScience()
	if self._sciLabel then
		self._sciLabel.Text = ("Science: %d"):format(sci)
	end
	local LINE_ON = Color3.fromRGB(80, 200, 120)
	local LINE_OFF = Color3.fromRGB(48, 60, 54)
	for i, tier in ipairs(TechTree.tiers) do
		local t = self._tierNodes[i]
		if t then
			local unlocked = self._state.unlocked[tier.id]
			local prev = TechTree.prevTierId(tier.id)
			local available = (not unlocked) and (not prev or self._state.unlocked[prev])

			local strokeColor, chipColor, chipText, chipActive
			if unlocked then
				strokeColor, chipColor, chipText, chipActive = GREEN, GREEN, "UNLOCKED", false
			elseif available then
				local afford = sci >= tier.cost
				strokeColor = ACCENT
				chipColor = afford and GREEN or GREY
				chipText = (tier.cost == 0) and "FREE" or ("Unlock %d"):format(tier.cost)
				chipActive = afford
			else
				strokeColor, chipColor, chipText, chipActive = GREY, GREY, ("Locked  %d"):format(tier.cost), false
			end

			for _, s in ipairs(t.strokes) do
				s.Color = strokeColor
			end
			t.chip.Text = chipText
			t.chip.BackgroundColor3 = chipColor
			t.chip.AutoButtonColor = chipActive
			t.chip.Active = chipActive

			-- Colour the bus that feeds this tier green once it's unlocked.
			if self._tierConns and self._tierConns[i] then
				for _, f in ipairs(self._tierConns[i]) do
					f.BackgroundColor3 = unlocked and LINE_ON or LINE_OFF
				end
			end
		end
	end
end

function TechController:_toast(text)
	if not self._toastLabel then
		return
	end
	self._toastLabel.Text = text
	self._toastLabel.Visible = true
	self._toastToken += 1
	local token = self._toastToken
	task.delay(3.5, function()
		if self._toastToken == token and self._toastLabel then
			self._toastLabel.Visible = false
		end
	end)
end

return TechController
