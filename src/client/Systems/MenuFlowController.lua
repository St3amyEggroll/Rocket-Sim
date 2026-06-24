--[[
	MenuFlowController
	The front-end flow shown over the live (cinematic) game scene:

	  Main Menu ──> [Play]     ──> Mode Select ──> [Single Player] ──> Save Slots ──> [Enter]
	            └─> [Settings]                      [Multiplayer = disabled]            └─> in-game (VAB)

	Each page is bound to a GameModeController menu state (MainMenu / Settings / ModeSelect /
	SaveSelect). Save slots are read/written through ReplicatedStorage.GameRemotes (SaveServer);
	entering a slot loads it and switches to the in-game VAB.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local MenuFlowController = {}

local SLOTS = 3
local BG = Color3.fromRGB(14, 17, 24)
local PANEL = Color3.fromRGB(20, 24, 32)
local ROW = Color3.fromRGB(34, 38, 48)
local ACCENT = Color3.fromRGB(120, 200, 255)
local GREEN = Color3.fromRGB(60, 170, 90)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function button(parent, text, size, pos, color)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos
	b.AnchorPoint = Vector2.new(0.5, 0)
	b.BackgroundColor3 = color or ROW
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 18
	b.TextColor3 = TEXT
	b.Text = text
	corner(b, 8)
	b.Parent = parent
	return b
end

function MenuFlowController:Init() end

function MenuFlowController:Start()
	self._mode = Registry:Get("GameModeController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._listFn = remotes:WaitForChild("ListSaves")
		self._loadFn = remotes:WaitForChild("LoadSave")
		self._newFn = remotes:WaitForChild("NewGame")
		self._delFn = remotes:WaitForChild("DeleteSave")
	end

	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))
	self._mode.ModeChanged:Connect(function(m)
		self:_onMode(m)
	end)
	self:_onMode(self._mode:GetMode())
end

function MenuFlowController:_onMode(m)
	if not self._gui then
		return
	end
	self._gui.Enabled = self._mode:IsMenu()
	self._pages.MainMenu.Visible = (m == "MainMenu")
	self._pages.Settings.Visible = (m == "Settings")
	self._pages.ModeSelect.Visible = (m == "ModeSelect")
	self._pages.SaveSelect.Visible = (m == "SaveSelect")
	if m == "SaveSelect" then
		self:_refreshSlots()
	end
end

function MenuFlowController:_build(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "MenuFlow"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 90
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui
	self._pages = {}

	self:_buildMain(gui)
	self:_buildSettings(gui)
	self:_buildModeSelect(gui)
	self:_buildSaveSelect(gui)
end

-- A translucent page frame (the cinematic scene shows behind it).
function MenuFlowController:_page(gui, opaque)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = BG
	f.BackgroundTransparency = opaque and 0.35 or 1
	f.BorderSizePixel = 0
	f.Visible = false
	f.Parent = gui
	return f
end

function MenuFlowController:_panel(parent, size)
	local p = Instance.new("Frame")
	p.AnchorPoint = Vector2.new(0.5, 0.5)
	p.Position = UDim2.fromScale(0.5, 0.5)
	p.Size = size
	p.BackgroundColor3 = PANEL
	p.BackgroundTransparency = 0.1
	p.BorderSizePixel = 0
	corner(p, 12)
	p.Parent = parent
	return p
end

function MenuFlowController:_titleLabel(parent, text, y, sizePx, color)
	local t = Instance.new("TextLabel")
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Position = UDim2.new(0.5, 0, 0, y)
	t.Size = UDim2.fromOffset(560, sizePx + 8)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBold
	t.TextSize = sizePx
	t.TextColor3 = color or TEXT
	t.Text = text
	t.Parent = parent
	return t
end

function MenuFlowController:_buildMain(gui)
	local page = self:_page(gui, false)
	self._pages.MainMenu = page
	self:_titleLabel(page, "ROCKET  SIM", 140, 48, ACCENT)
	self:_titleLabel(page, "a tiny space program", 196, 16, DIM)
	button(page, "PLAY", UDim2.fromOffset(240, 48), UDim2.new(0.5, 0, 0, 280), GREEN).Activated:Connect(function()
		self._mode:SetMode("ModeSelect")
	end)
	button(page, "SETTINGS", UDim2.fromOffset(240, 44), UDim2.new(0.5, 0, 0, 340)).Activated:Connect(function()
		self._mode:SetMode("Settings")
	end)
end

function MenuFlowController:_buildSettings(gui)
	local page = self:_page(gui, true)
	self._pages.Settings = page
	local p = self:_panel(page, UDim2.fromOffset(380, 220))
	self:_titleLabel(p, "SETTINGS", 18, 20, ACCENT)
	local soon = Instance.new("TextLabel")
	soon.AnchorPoint = Vector2.new(0.5, 0.5)
	soon.Position = UDim2.fromScale(0.5, 0.5)
	soon.Size = UDim2.fromOffset(340, 40)
	soon.BackgroundTransparency = 1
	soon.Font = Enum.Font.Gotham
	soon.TextSize = 16
	soon.TextColor3 = DIM
	soon.Text = "Coming soon."
	soon.Parent = p
	button(p, "Back", UDim2.fromOffset(160, 36), UDim2.new(0.5, 0, 1, -52)).Activated:Connect(function()
		self._mode:SetMode("MainMenu")
	end)
end

function MenuFlowController:_buildModeSelect(gui)
	local page = self:_page(gui, true)
	self._pages.ModeSelect = page
	local p = self:_panel(page, UDim2.fromOffset(440, 260))
	self:_titleLabel(p, "SELECT MODE", 18, 20, ACCENT)

	local sp = button(p, "SINGLE PLAYER", UDim2.fromOffset(360, 48), UDim2.new(0.5, 0, 0, 70), GREEN)
	sp.Activated:Connect(function()
		self._mode:SetMode("SaveSelect")
	end)

	local mp = button(p, "MULTIPLAYER  (coming soon)", UDim2.fromOffset(360, 48), UDim2.new(0.5, 0, 0, 130), ROW)
	mp.AutoButtonColor = false
	mp.Active = false
	mp.TextColor3 = DIM

	button(p, "Back", UDim2.fromOffset(160, 36), UDim2.new(0.5, 0, 1, -52)).Activated:Connect(function()
		self._mode:SetMode("MainMenu")
	end)
end

function MenuFlowController:_buildSaveSelect(gui)
	local page = self:_page(gui, true)
	self._pages.SaveSelect = page
	local p = self:_panel(page, UDim2.fromOffset(460, 120 + SLOTS * 76))
	self:_titleLabel(p, "SAVE SLOTS", 18, 20, ACCENT)

	self._slotRows = {}
	for i = 1, SLOTS do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -32, 0, 66)
		row.Position = UDim2.fromOffset(16, 56 + (i - 1) * 76)
		row.BackgroundColor3 = ROW
		row.BorderSizePixel = 0
		corner(row, 8)
		row.Parent = p

		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromOffset(14, 0)
		label.Size = UDim2.new(1, -210, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 15
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = TEXT
		label.Text = "Slot " .. i
		label.Parent = row

		local enter = Instance.new("TextButton")
		enter.AnchorPoint = Vector2.new(1, 0.5)
		enter.Position = UDim2.new(1, -12, 0.5, 0)
		enter.Size = UDim2.fromOffset(96, 38)
		enter.BackgroundColor3 = GREEN
		enter.BorderSizePixel = 0
		enter.Font = Enum.Font.GothamBold
		enter.TextSize = 14
		enter.TextColor3 = Color3.fromRGB(255, 255, 255)
		enter.Text = "Enter"
		corner(enter, 6)
		enter.Parent = row
		enter.Activated:Connect(function()
			self:_enterSlot(i)
		end)

		local del = Instance.new("TextButton")
		del.AnchorPoint = Vector2.new(1, 0.5)
		del.Position = UDim2.new(1, -116, 0.5, 0)
		del.Size = UDim2.fromOffset(70, 38)
		del.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
		del.BorderSizePixel = 0
		del.Font = Enum.Font.GothamBold
		del.TextSize = 13
		del.TextColor3 = Color3.fromRGB(255, 255, 255)
		del.Text = "Delete"
		corner(del, 6)
		del.Parent = row
		del.Activated:Connect(function()
			self:_deleteSlot(i)
		end)

		self._slotRows[i] = { row = row, label = label, enter = enter, del = del, empty = true }
	end

	button(p, "Back", UDim2.fromOffset(160, 34), UDim2.new(0.5, 0, 1, -46)).Activated:Connect(function()
		self._mode:SetMode("ModeSelect")
	end)
end

function MenuFlowController:_refreshSlots()
	if not self._slotRows then
		return
	end
	-- Default to "loading" while we query, then fill in.
	for i, r in ipairs(self._slotRows) do
		r.label.Text = "Slot " .. i .. "  -  ..."
	end
	task.spawn(function()
		local list = self._listFn and self._listFn:InvokeServer() or {}
		for i, r in ipairs(self._slotRows) do
			local info = list[i]
			if info and not info.empty then
				r.empty = false
				r.label.Text = ("%s\nScience %d"):format(info.name or ("Save " .. i), info.science or 0)
				r.enter.Text = "Enter"
				r.del.Visible = true
			else
				r.empty = true
				r.label.Text = "Slot " .. i .. "  -  Empty"
				r.enter.Text = "New Game"
				r.del.Visible = false
			end
		end
	end)
end

function MenuFlowController:_enterSlot(i)
	task.spawn(function()
		local r = self._slotRows[i]
		local ok
		if r and r.empty then
			ok = self._newFn and self._newFn:InvokeServer(i, "Save " .. i)
		else
			ok = self._loadFn and self._loadFn:InvokeServer(i)
		end
		if ok then
			self._mode:SetMode("VAB") -- enter the game
		end
	end)
end

function MenuFlowController:_deleteSlot(i)
	task.spawn(function()
		if self._delFn then
			self._delFn:InvokeServer(i)
		end
		self:_refreshSlots()
	end)
end

return MenuFlowController
