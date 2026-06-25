--[[
	MenuController
	Owner of: the in-flight menu and the crash overlay.

	Shown only in Flight mode. A top-right MENU button opens a small panel with
	"Back to Launch Site" (KSP revert-to-launch), "Revert to Build" (back to building)
	and "Resume". When the craft is Crashed a centered overlay offers the same two
	recovery actions, so you are never stuck on a wreck.

	It only drives GameModeController (ReturnToLaunch / SetMode); it owns no state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))

local MenuController = {}

local DARK = Color3.fromRGB(16, 18, 26)
local ACCENT = Color3.fromRGB(120, 200, 255)
local GREEN = Color3.fromRGB(60, 170, 90)
local AMBER = Color3.fromRGB(210, 150, 60)
local RED = Color3.fromRGB(200, 70, 70)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function button(parent, text, color, size)
	local b = Instance.new("TextButton")
	b.Size = size
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Text = text
	b.Parent = parent
	corner(b, 8)
	return b
end

function MenuController:Init() end

function MenuController:Start()
	self._mode = Registry:Get("GameModeController")
	local Flight = Registry:Get("FlightController")
	local player = Players.LocalPlayer

	self:_build(player:WaitForChild("PlayerGui"))

	self._gui.Enabled = (self._mode:GetMode() == "Flight")
	self._mode.ModeChanged:Connect(function(m)
		self._gui.Enabled = (m == "Flight")
		self:_setMenuOpen(false)
	end)

	-- Show the crash card ~1s after the crash so the tip-over animation plays first.
	Flight:GetUpdatedSignal():Connect(function(_, info)
		local crashed = info.mode == "Flight" and info.status == "Crashed"
		if crashed then
			self._crashStart = self._crashStart or os.clock()
			local show = (os.clock() - self._crashStart) >= 1.0
			if show ~= self._crashOverlay.Visible then
				self._crashOverlay.Visible = show
				if show then
					self:_setMenuOpen(false)
				end
			end
		else
			self._crashStart = nil
			if self._crashOverlay.Visible then
				self._crashOverlay.Visible = false
			end
		end
	end)
end

function MenuController:_setMenuOpen(open)
	self._menuOpen = open
	self._menuPanel.Visible = open
	self._menuBtn.Text = open and "CLOSE" or "MENU"
end

function MenuController:_returnToLaunch()
	self:_setMenuOpen(false)
	self._mode:ReturnToLaunch()
end

function MenuController:_revertToVAB()
	self:_setMenuOpen(false)
	self._mode:SetMode("VAB")
end

function MenuController:_build(parentGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Parent = parentGui
	self._gui = gui

	-- MENU toggle (top-right).
	local menuBtn = button(gui, "MENU", DARK, UDim2.fromOffset(120, 36))
	menuBtn.AnchorPoint = Vector2.new(1, 0)
	menuBtn.Position = UDim2.new(1, -16, 0, 16)
	menuBtn.BackgroundTransparency = 0.1
	menuBtn.TextColor3 = ACCENT
	menuBtn.TextSize = 15
	self._menuBtn = menuBtn
	menuBtn.Activated:Connect(function()
		self:_setMenuOpen(not self._menuOpen)
	end)

	-- Dropdown panel.
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 60)
	panel.Size = UDim2.fromOffset(248, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = DARK
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	corner(panel, 10)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.Parent = panel
	self._menuPanel = panel

	local toLaunch = button(panel, "Back to Launch Site", GREEN, UDim2.new(1, 0, 0, 44))
	toLaunch.Activated:Connect(function()
		self:_returnToLaunch()
	end)
	local toVAB = button(panel, "Revert to Build", AMBER, UDim2.new(1, 0, 0, 44))
	toVAB.Activated:Connect(function()
		self:_revertToVAB()
	end)
	local resume = button(panel, "Resume", Color3.fromRGB(50, 56, 70), UDim2.new(1, 0, 0, 38))
	resume.TextSize = 14
	resume.Activated:Connect(function()
		self:_setMenuOpen(false)
	end)

	-- Crash overlay (dim + centered card).
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.45
	overlay.BorderSizePixel = 0
	overlay.Active = true -- modal: swallow clicks meant for the dimmed UI behind it
	overlay.Visible = false
	overlay.ZIndex = 5
	overlay.Parent = gui
	self._crashOverlay = overlay

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(380, 220)
	card.BackgroundColor3 = DARK
	card.BorderSizePixel = 0
	card.ZIndex = 6
	card.Parent = overlay
	corner(card, 12)
	local stroke = Instance.new("UIStroke")
	stroke.Color = RED
	stroke.Thickness = 2
	stroke.Parent = card

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 44)
	title.Position = UDim2.fromOffset(0, 22)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 30
	title.TextColor3 = RED
	title.Text = "CRASHED"
	title.ZIndex = 7
	title.Parent = card

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, -32, 0, 24)
	sub.Position = UDim2.fromOffset(16, 70)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Gotham
	sub.TextSize = 14
	sub.TextColor3 = Color3.fromRGB(200, 206, 216)
	sub.Text = "Your vessel was destroyed."
	sub.ZIndex = 7
	sub.Parent = card

	local b1 = button(card, "Back to Launch Site", GREEN, UDim2.fromOffset(348, 48))
	b1.AnchorPoint = Vector2.new(0.5, 0)
	b1.Position = UDim2.new(0.5, 0, 0, 110)
	b1.ZIndex = 7
	b1.Activated:Connect(function()
		self:_returnToLaunch()
	end)

	local b2 = button(card, "Revert to Build", AMBER, UDim2.fromOffset(348, 44))
	b2.AnchorPoint = Vector2.new(0.5, 0)
	b2.Position = UDim2.new(0.5, 0, 0, 164)
	b2.ZIndex = 7
	b2.Activated:Connect(function()
		self:_revertToVAB()
	end)

	self._menuOpen = false
	self._crashStart = nil
end

return MenuController
