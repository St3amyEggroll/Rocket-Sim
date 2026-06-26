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

-- A one-line stat summary for a part, shown in the info panel.
local function statText(def)
	local s = ("%.2f t"):format(def.mass or 0)
	if def.category == "engine" then
		s = s .. ("  •  thrust %d"):format(def.thrust or 0)
		if def.fuel then
			s = s .. ("  •  solid")
		end
	elseif def.fuel then
		s = s .. ("  •  fuel %.1f"):format(def.fuel)
	elseif def.chuteDrag then
		s = s .. "  •  parachute"
	elseif def.landingLeg then
		s = s .. "  •  landing legs"
	end
	return s
end

-- A row in the info panel's parts list: a 3D part icon + name + one-line stats.
local function partRow(parent, def, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -6, 0, 46)
	row.BackgroundColor3 = ROW
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	corner(row, 6)
	row.Parent = parent

	local thumb = PartPreview.thumbnail(def)
	thumb.Size = UDim2.fromOffset(38, 38)
	thumb.Position = UDim2.fromOffset(4, 4)
	corner(thumb, 5)
	thumb.Parent = row

	local name = Instance.new("TextLabel")
	name.Position = UDim2.fromOffset(50, 5)
	name.Size = UDim2.new(1, -56, 0, 20)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 13
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = TEXT
	name.Text = def.name
	name.Parent = row

	local stat = Instance.new("TextLabel")
	stat.Position = UDim2.fromOffset(50, 25)
	stat.Size = UDim2.new(1, -56, 0, 16)
	stat.BackgroundTransparency = 1
	stat.Font = Enum.Font.Code
	stat.TextSize = 11
	stat.TextXAlignment = Enum.TextXAlignment.Left
	stat.TextColor3 = DIM
	stat.Text = statText(def)
	stat.Parent = row

	return row
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
	self:_refreshInfo()
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
	local R = self._reported
	local bodyId = info.bodyId
	if bodyId == "planet" then
		-- Once every Terra milestone is earned there's nothing left to detect: skip the
		-- per-frame sqrt + orbit readout for the rest of the flight.
		if R.alt5k and R.alt25k and R.space and R.orbit then
			return
		end
		local p = state.position
		local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		local alt = r - (info.bodyRadius or 0)
		reportIf(self, alt > 5000, "alt5k")
		reportIf(self, alt > 25000, "alt25k")
		reportIf(self, alt > Config.ATMOSPHERE.top, "space")
		-- Stable orbit: periapsis clears the atmosphere (won't reenter).
		if not R.orbit then
			local ro = Orbit.getReadout(state, info.mu)
			if ro and ro.periapsis and (ro.periapsis - (info.bodyRadius or 0)) > Config.ATMOSPHERE.top then
				reportIf(self, true, "orbit")
			end
		end
	elseif bodyId == "moon" then
		if R.munSOI and R.munLand then
			return
		end
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

	-- Scrollable graph canvas (left side). The info panel sits to its right.
	local INFO_W = 312
	local graph = Instance.new("ScrollingFrame")
	graph.Position = UDim2.fromOffset(12, 48)
	graph.Size = UDim2.new(1, -(INFO_W + 36), 1, -60)
	graph.BackgroundColor3 = Color3.fromRGB(9, 12, 18)
	graph.BackgroundTransparency = 0.2
	graph.BorderSizePixel = 0
	graph.ScrollBarThickness = 6
	graph.ScrollingDirection = Enum.ScrollingDirection.XY
	graph.CanvasSize = UDim2.new()
	corner(graph, 10)
	graph.Parent = panel

	self:_buildGraph(graph)
	self:_buildInfo(panel, INFO_W)
	self:_refreshTree()
	self:_selectNode(TechTree.nodes[1] and TechTree.nodes[1].id)
end

-- Right-side info panel: the selected node's name, status/cost, the parts it grants, and a
-- research button. Populated by _refreshInfo whenever the selection or progress changes.
function TechController:_buildInfo(panel, INFO_W)
	local info = Instance.new("Frame")
	info.AnchorPoint = Vector2.new(1, 0)
	info.Position = UDim2.new(1, -12, 0, 48)
	info.Size = UDim2.new(0, INFO_W, 1, -60)
	info.BackgroundColor3 = Color3.fromRGB(15, 19, 26)
	info.BackgroundTransparency = 0.05
	info.BorderSizePixel = 0
	corner(info, 10)
	info.Parent = panel

	self._infoName = Instance.new("TextLabel")
	self._infoName.Position = UDim2.fromOffset(14, 12)
	self._infoName.Size = UDim2.new(1, -28, 0, 26)
	self._infoName.BackgroundTransparency = 1
	self._infoName.Font = Enum.Font.GothamBold
	self._infoName.TextSize = 18
	self._infoName.TextXAlignment = Enum.TextXAlignment.Left
	self._infoName.TextColor3 = ACCENT
	self._infoName.Text = ""
	self._infoName.Parent = info

	self._infoStatus = Instance.new("TextLabel")
	self._infoStatus.Position = UDim2.fromOffset(14, 40)
	self._infoStatus.Size = UDim2.new(1, -28, 0, 30)
	self._infoStatus.BackgroundTransparency = 1
	self._infoStatus.Font = Enum.Font.Gotham
	self._infoStatus.TextSize = 13
	self._infoStatus.TextWrapped = true
	self._infoStatus.TextXAlignment = Enum.TextXAlignment.Left
	self._infoStatus.TextYAlignment = Enum.TextYAlignment.Top
	self._infoStatus.TextColor3 = DIM
	self._infoStatus.Text = ""
	self._infoStatus.Parent = info

	local hdr = Instance.new("TextLabel")
	hdr.Position = UDim2.fromOffset(14, 76)
	hdr.Size = UDim2.new(1, -28, 0, 16)
	hdr.BackgroundTransparency = 1
	hdr.Font = Enum.Font.GothamBold
	hdr.TextSize = 12
	hdr.TextXAlignment = Enum.TextXAlignment.Left
	hdr.TextColor3 = Color3.fromRGB(120, 128, 140)
	hdr.Text = "PARTS GRANTED"
	hdr.Parent = info

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(10, 96)
	list.Size = UDim2.new(1, -20, 1, -148)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 5
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = info
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 6)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Parent = list
	self._infoParts = list
	self._infoRows = {}

	self._infoBtn = Instance.new("TextButton")
	self._infoBtn.AnchorPoint = Vector2.new(0.5, 1)
	self._infoBtn.Position = UDim2.new(0.5, 0, 1, -12)
	self._infoBtn.Size = UDim2.new(1, -28, 0, 38)
	self._infoBtn.BackgroundColor3 = GREY
	self._infoBtn.BorderSizePixel = 0
	self._infoBtn.Font = Enum.Font.GothamBold
	self._infoBtn.TextSize = 15
	self._infoBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	self._infoBtn.Text = ""
	corner(self._infoBtn, 8)
	self._infoBtn.Parent = info
	self._infoBtn.Activated:Connect(function()
		if self._selectedNode then
			self:_requestUnlock(self._selectedNode)
		end
	end)
end

-- Select a node: show its details on the right (and re-highlight it in the graph).
function TechController:_selectNode(id)
	if not id then
		return
	end
	self._selectedNode = id
	self:_refreshInfo()
	self:_refreshTree()
end

function TechController:_refreshInfo()
	if not self._infoName then
		return
	end
	for _, c in ipairs(self._infoRows) do
		c:Destroy()
	end
	self._infoRows = {}

	local node = self._selectedNode and TechTree.nodeById(self._selectedNode)
	if not node then
		self._infoName.Text = "Select a node"
		self._infoStatus.Text = ""
		self._infoBtn.Visible = false
		return
	end
	self._infoBtn.Visible = true

	local unlocked = self._state.unlocked or {}
	local isUnlocked = unlocked[node.id] == true
	local available = (not isUnlocked) and TechTree.requiresMet(node, unlocked)
	local sci = self:GetScience()
	local SCI = Color3.fromRGB(150, 235, 170)

	self._infoName.Text = node.name
	if isUnlocked then
		self._infoStatus.Text = "Researched"
		self._infoStatus.TextColor3 = SCI
	elseif available then
		self._infoStatus.Text = (node.cost == 0) and "Available  •  Free"
			or ("Available  •  costs %d science"):format(node.cost)
		self._infoStatus.TextColor3 = (sci >= node.cost) and SCI or DIM
	else
		local reqNames = {}
		for _, r in ipairs(node.requires) do
			local rn = TechTree.nodeById(r)
			reqNames[#reqNames + 1] = rn and rn.name or r
		end
		self._infoStatus.Text = "Locked  •  research " .. table.concat(reqNames, " or ") .. " first"
		self._infoStatus.TextColor3 = DIM
	end

	for i, partId in ipairs(node.parts) do
		local def = Catalog.get(partId)
		if def then
			self._infoRows[#self._infoRows + 1] = partRow(self._infoParts, def, i)
		end
	end

	if isUnlocked then
		self._infoBtn.Text = "Researched ✓"
		self._infoBtn.BackgroundColor3 = Color3.fromRGB(40, 70, 52)
		self._infoBtn.Active = false
		self._infoBtn.AutoButtonColor = false
	elseif available then
		local afford = sci >= node.cost
		self._infoBtn.Text = (node.cost == 0) and "Research (Free)" or ("Research  (%d)"):format(node.cost)
		self._infoBtn.BackgroundColor3 = afford and GREEN or GREY
		self._infoBtn.Active = afford
		self._infoBtn.AutoButtonColor = afford
	else
		self._infoBtn.Text = "Locked"
		self._infoBtn.BackgroundColor3 = GREY
		self._infoBtn.Active = false
		self._infoBtn.AutoButtonColor = false
	end
end

-- Lay out the BRANCHING tech graph: one box per node placed on its (col,row) grid cell, each
-- node wired back to its prerequisite(s) with right-angle (elbow) connectors. Stores per-node
-- UI handles and per-node incoming-edge frames so _refreshTree can recolour them by state.
function TechController:_buildGraph(parent)
	local NODE_W = 126
	local NODE_H = 58
	local COL_W = 174
	local ROW_H = 78
	local PAD_X = 28
	local PAD_TOP = 22

	local maxCol, maxRow = 0, 0
	for _, n in ipairs(TechTree.nodes) do
		maxCol = math.max(maxCol, n.col)
		maxRow = math.max(maxRow, n.row)
	end
	parent.CanvasSize = UDim2.fromOffset(PAD_X * 2 + maxCol * COL_W + NODE_W, PAD_TOP * 2 + maxRow * ROW_H + NODE_H)

	local function nodeXY(n)
		return PAD_X + n.col * COL_W, PAD_TOP + n.row * ROW_H
	end

	-- Thin line segment helper (a Frame). Edges are drawn first so the node boxes sit on top.
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

	-- ---- edges (parent right edge -> elbow -> child left edge) ----
	self._edges = {} -- [childId] = { frames... }
	for _, n in ipairs(TechTree.nodes) do
		for _, reqId in ipairs(n.requires) do
			local pnode = TechTree.nodeById(reqId)
			if pnode then
				local px, py = nodeXY(pnode)
				local cx, cy = nodeXY(n)
				local x1, y1 = px + NODE_W, py + NODE_H / 2 -- parent right-centre
				local x2, y2 = cx, cy + NODE_H / 2 -- child left-centre
				local midX = (x1 + x2) / 2
				local e = self._edges[n.id] or {}
				e[#e + 1] = seg(x1, y1 - 1, midX - x1 + 1, 2) -- out of parent
				e[#e + 1] = seg(midX - 1, math.min(y1, y2), 2, math.abs(y2 - y1) + 2) -- vertical run
				e[#e + 1] = seg(midX, y2 - 1, x2 - midX, 2) -- into child
				self._edges[n.id] = e
			end
		end
	end

	-- ---- node boxes (icon + name + cost/status) ----
	self._nodeUI = {} -- [id] = { stroke, status }
	for _, n in ipairs(TechTree.nodes) do
		local x, y = nodeXY(n)

		local box = Instance.new("TextButton")
		box.Position = UDim2.fromOffset(x, y)
		box.Size = UDim2.fromOffset(NODE_W, NODE_H)
		box.BackgroundColor3 = Color3.fromRGB(20, 26, 22)
		box.AutoButtonColor = true
		box.BorderSizePixel = 0
		box.Text = ""
		box.ZIndex = 2
		corner(box, 8)
		box.Parent = parent
		box.Activated:Connect(function()
			self:_selectNode(n.id)
		end)

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = GREY
		stroke.Parent = box

		local def = Catalog.get(n.parts[1]) -- representative icon (first part)
		if def then
			local thumb = PartPreview.thumbnail(def)
			thumb.Size = UDim2.fromOffset(NODE_H - 12, NODE_H - 12)
			thumb.Position = UDim2.fromOffset(6, 6)
			thumb.ZIndex = 3
			thumb.Parent = box
		end

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(NODE_H, 6)
		name.Size = UDim2.fromOffset(NODE_W - NODE_H - 6, 30)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBold
		name.TextSize = 12
		name.TextWrapped = true
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextYAlignment = Enum.TextYAlignment.Top
		name.TextColor3 = TEXT
		name.Text = n.name
		name.ZIndex = 3
		name.Parent = box

		local status = Instance.new("TextLabel")
		status.AnchorPoint = Vector2.new(0, 1)
		status.Position = UDim2.fromOffset(NODE_H, NODE_H - 6)
		status.Size = UDim2.fromOffset(NODE_W - NODE_H - 6, 16)
		status.BackgroundTransparency = 1
		status.Font = Enum.Font.GothamBold
		status.TextSize = 12
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.TextColor3 = DIM
		status.Text = ""
		status.ZIndex = 3
		status.Parent = box

		self._nodeUI[n.id] = { stroke = stroke, status = status }
	end
end

function TechController:_setResearchVisible(v)
	if self._gui then
		self._gui.Enabled = v
	end
end

function TechController:_refreshTree()
	if not self._nodeUI then
		return
	end
	local sci = self:GetScience()
	if self._sciLabel then
		self._sciLabel.Text = ("Science: %d"):format(sci)
	end
	local unlocked = self._state.unlocked or {}
	local SCI_TXT = Color3.fromRGB(150, 235, 170)
	local LINE_ON = Color3.fromRGB(80, 200, 120)
	local LINE_OFF = Color3.fromRGB(48, 60, 54)
	for _, n in ipairs(TechTree.nodes) do
		local ui = self._nodeUI[n.id]
		if ui then
			local isUnlocked = unlocked[n.id] == true
			local available = (not isUnlocked) and TechTree.requiresMet(n, unlocked)
			if isUnlocked then
				ui.stroke.Color = GREEN
				ui.status.Text = "Researched"
				ui.status.TextColor3 = SCI_TXT
			elseif available then
				local afford = sci >= n.cost
				ui.stroke.Color = ACCENT
				ui.status.Text = (n.cost == 0) and "FREE" or (("%d pts"):format(n.cost))
				ui.status.TextColor3 = afford and SCI_TXT or DIM
			else
				ui.stroke.Color = GREY
				ui.status.Text = ("%d pts"):format(n.cost)
				ui.status.TextColor3 = Color3.fromRGB(110, 116, 128)
			end
			-- The selected node gets a brighter, thicker outline.
			if n.id == self._selectedNode then
				ui.stroke.Thickness = 3.5
				ui.stroke.Color = Color3.fromRGB(255, 255, 255)
			else
				ui.stroke.Thickness = 2
			end
		end
		-- Incoming edge(s) light up green once this node is researched (the path was taken).
		if self._edges and self._edges[n.id] then
			local on = unlocked[n.id] == true
			for _, f in ipairs(self._edges[n.id]) do
				f.BackgroundColor3 = on and LINE_ON or LINE_OFF
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
