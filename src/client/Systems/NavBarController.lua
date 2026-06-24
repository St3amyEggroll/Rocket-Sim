--[[
	NavBarController
	The in-game top navigation bar: Build (VAB) | Research (tech tree) | Launch, plus a Menu
	button back to the front-end. Shown while in the game and NOT flying (VAB / Research); in
	flight the existing MenuController handles navigation. Drives GameModeController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local NavBarController = {}

local BG = Color3.fromRGB(18, 21, 28)
local ROW = Color3.fromRGB(34, 38, 48)
local ACTIVE = Color3.fromRGB(120, 200, 255)
local TEXT = Color3.fromRGB(225, 230, 238)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

function NavBarController:Init() end

function NavBarController:Start()
	self._mode = Registry:Get("GameModeController")
	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))

	self._mode.ModeChanged:Connect(function()
		self:_refresh()
	end)
	self:_refresh()
end

function NavBarController:_build(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "NavBar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 70
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 8)
	bar.Size = UDim2.fromOffset(440, 40)
	bar.BackgroundColor3 = BG
	bar.BackgroundTransparency = 0.15
	bar.BorderSizePixel = 0
	corner(bar, 10)
	bar.Parent = gui

	local function tab(text, x, w, onClick)
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(x, 5)
		b.Size = UDim2.fromOffset(w, 30)
		b.BackgroundColor3 = ROW
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = TEXT
		b.Text = text
		corner(b, 6)
		b.Parent = bar
		b.Activated:Connect(onClick)
		return b
	end

	self._buildBtn = tab("BUILD", 8, 110, function()
		self._mode:SetMode("VAB")
	end)
	self._researchBtn = tab("RESEARCH", 122, 110, function()
		self._mode:SetMode("Research")
	end)
	self._launchBtn = tab("LAUNCH", 236, 110, function()
		self._mode:SetMode("Flight")
	end)
	self._launchBtn.BackgroundColor3 = Color3.fromRGB(60, 150, 90)

	-- Menu button (back to the front-end), set apart on the right.
	self._menuBtn = Instance.new("TextButton")
	self._menuBtn.AnchorPoint = Vector2.new(1, 0)
	self._menuBtn.Position = UDim2.new(1, -8, 0, 5)
	self._menuBtn.Size = UDim2.fromOffset(34, 30)
	self._menuBtn.BackgroundColor3 = ROW
	self._menuBtn.BorderSizePixel = 0
	self._menuBtn.Font = Enum.Font.GothamBold
	self._menuBtn.TextSize = 16
	self._menuBtn.TextColor3 = TEXT
	self._menuBtn.Text = "≡"
	corner(self._menuBtn, 6)
	self._menuBtn.Parent = bar
	self._menuBtn.Activated:Connect(function()
		self._mode:SetMode("MainMenu")
	end)
end

function NavBarController:_refresh()
	if not self._gui then
		return
	end
	local m = self._mode:GetMode()
	-- The bar belongs to the build/research areas; hidden while flying and in the front-end.
	self._gui.Enabled = (m == "VAB" or m == "Research")
	self._buildBtn.BackgroundColor3 = (m == "VAB") and ACTIVE or ROW
	self._buildBtn.TextColor3 = (m == "VAB") and BG or TEXT
	self._researchBtn.BackgroundColor3 = (m == "Research") and ACTIVE or ROW
	self._researchBtn.TextColor3 = (m == "Research") and BG or TEXT
end

return NavBarController
