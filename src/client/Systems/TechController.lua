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
	-- a dim full-screen backdrop with the tech-tree panel.
	local gui = Instance.new("ScreenGui")
	gui.Name = "ResearchGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 55
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
	backdrop.BackgroundTransparency = 0.25
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(460, 520)
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	corner(panel, 12)
	panel.Parent = gui
	self._panel = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.new(1, -200, 0, 24)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = ACCENT
	title.Text = "RESEARCH"
	title.Parent = panel

	self._sciLabel = Instance.new("TextLabel")
	self._sciLabel.AnchorPoint = Vector2.new(1, 0)
	self._sciLabel.Position = UDim2.new(1, -16, 0, 14)
	self._sciLabel.Size = UDim2.fromOffset(180, 20)
	self._sciLabel.BackgroundTransparency = 1
	self._sciLabel.Font = Enum.Font.GothamBold
	self._sciLabel.TextSize = 15
	self._sciLabel.TextXAlignment = Enum.TextXAlignment.Right
	self._sciLabel.TextColor3 = Color3.fromRGB(150, 235, 170)
	self._sciLabel.Text = "Science: 0"
	self._sciLabel.Parent = panel

	local back = Instance.new("TextButton")
	back.AnchorPoint = Vector2.new(0.5, 1)
	back.Position = UDim2.new(0.5, 0, 1, -12)
	back.Size = UDim2.fromOffset(180, 30)
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

	local list = Instance.new("Frame")
	list.Position = UDim2.fromOffset(14, 46)
	list.Size = UDim2.new(1, -28, 1, -98)
	list.BackgroundTransparency = 1
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	self._tierRows = {}
	for i, tier in ipairs(TechTree.tiers) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 64)
		row.BackgroundColor3 = ROW
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		corner(row, 8)
		row.Parent = list

		local name = Instance.new("TextLabel")
		name.Position = UDim2.fromOffset(12, 8)
		name.Size = UDim2.new(1, -150, 0, 18)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBold
		name.TextSize = 15
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextColor3 = TEXT
		name.Text = tier.name
		name.Parent = row

		local parts = Instance.new("TextLabel")
		parts.Position = UDim2.fromOffset(12, 30)
		parts.Size = UDim2.new(1, -150, 0, 28)
		parts.BackgroundTransparency = 1
		parts.Font = Enum.Font.Code
		parts.TextSize = 12
		parts.TextWrapped = true
		parts.TextXAlignment = Enum.TextXAlignment.Left
		parts.TextYAlignment = Enum.TextYAlignment.Top
		parts.TextColor3 = DIM
		parts.Text = table.concat(tier.parts, ", ")
		parts.Parent = row

		local btn = Instance.new("TextButton")
		btn.AnchorPoint = Vector2.new(1, 0.5)
		btn.Position = UDim2.new(1, -12, 0.5, 0)
		btn.Size = UDim2.fromOffset(116, 32)
		btn.BackgroundColor3 = GREY
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 13
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Text = "LOCKED"
		corner(btn, 6)
		btn.Parent = row
		btn.Activated:Connect(function()
			self:_requestUnlock(tier.id)
		end)

		self._tierRows[i] = { row = row, btn = btn }
	end

	self:_refreshTree()
end

function TechController:_setResearchVisible(v)
	if self._gui then
		self._gui.Enabled = v
	end
end

function TechController:_refreshTree()
	if not self._tierRows then
		return
	end
	local sci = self:GetScience()
	if self._sciLabel then
		self._sciLabel.Text = ("Science: %d"):format(sci)
	end
	for i, tier in ipairs(TechTree.tiers) do
		local r = self._tierRows[i]
		if r then
			local unlocked = self._state.unlocked[tier.id]
			local prev = TechTree.prevTierId(tier.id)
			local available = (not unlocked) and (not prev or self._state.unlocked[prev])
			if unlocked then
				r.btn.Text = "UNLOCKED"
				r.btn.BackgroundColor3 = GREEN
				r.btn.AutoButtonColor = false
				r.btn.Active = false
			elseif available then
				local afford = sci >= tier.cost
				r.btn.Text = ("Unlock (%d)"):format(tier.cost)
				r.btn.BackgroundColor3 = afford and GREEN or GREY
				r.btn.AutoButtonColor = afford
				r.btn.Active = afford
			else
				r.btn.Text = "LOCKED"
				r.btn.BackgroundColor3 = GREY
				r.btn.AutoButtonColor = false
				r.btn.Active = false
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
