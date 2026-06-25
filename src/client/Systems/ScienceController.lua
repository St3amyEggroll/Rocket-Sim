--[[
	ScienceController
	The in-flight SCIENCE widget (left edge): shows the craft's current situation
	(body / biome / situation) and a "Run Experiment" button that collects biome/situation
	science from the instruments on the craft.

	An experiment is collectable when the active craft carries its instrument part, the context
	allows it (Science.canRun), and you haven't already collected that { body, biome, situation }
	reading. Pressing the button reports each available reading to the server (which owns the
	value + the one-time dedup) over ReplicatedStorage.GameRemotes.RunExperiment; the collected
	set is mirrored from the State push.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Situations = require(Shared:WaitForChild("Situations"))
local Science = require(Shared:WaitForChild("Science"))

local ScienceController = {}

local BG = Color3.fromRGB(18, 21, 28)
local GREEN = Color3.fromRGB(60, 170, 90)
local GREY = Color3.fromRGB(52, 58, 68)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)
local SCI = Color3.fromRGB(150, 235, 170)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

function ScienceController:Init()
	self._collected = {}
	self._ctx = nil
	self._flashToken = 0
end

function ScienceController:Start()
	self._mode = Registry:Get("GameModeController")
	self._vehicle = Registry:Get("VehicleController")
	local Flight = Registry:Get("FlightController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._runEv = remotes:WaitForChild("RunExperiment")
		self._stateEv = remotes:WaitForChild("State")
		self._stateEv.OnClientEvent:Connect(function(state)
			if type(state) == "table" then
				self._collected = state.experiments or {}
				self:_refresh()
			end
		end)
		self._stateEv:FireServer() -- request our profile (so the collected set is current)
	end

	self:_build(Players.LocalPlayer:WaitForChild("PlayerGui"))

	self._mode.ModeChanged:Connect(function()
		self:_refresh()
	end)
	Flight:GetUpdatedSignal():Connect(function(state, info)
		self._ctx = (info and info.mode == "Flight" and info.status ~= "Crashed") and Situations.of(state, info) or nil
		self:_refresh()
	end)
end

function ScienceController:_build(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "ScienceWidget"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 60
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 12, 0.5, -10)
	panel.Size = UDim2.fromOffset(238, 104)
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	corner(panel, 10)
	panel.Parent = gui

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.new(1, -24, 0, 16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = SCI
	title.Text = "SCIENCE"
	title.Parent = panel

	self._sitLabel = Instance.new("TextLabel")
	self._sitLabel.Position = UDim2.fromOffset(12, 26)
	self._sitLabel.Size = UDim2.new(1, -24, 0, 18)
	self._sitLabel.BackgroundTransparency = 1
	self._sitLabel.Font = Enum.Font.Gotham
	self._sitLabel.TextSize = 13
	self._sitLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._sitLabel.TextColor3 = TEXT
	self._sitLabel.Text = "--"
	self._sitLabel.Parent = panel

	self._btn = Instance.new("TextButton")
	self._btn.Position = UDim2.fromOffset(12, 48)
	self._btn.Size = UDim2.new(1, -24, 0, 32)
	self._btn.BackgroundColor3 = GREY
	self._btn.BorderSizePixel = 0
	self._btn.Font = Enum.Font.GothamBold
	self._btn.TextSize = 14
	self._btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	self._btn.AutoButtonColor = false
	self._btn.Text = "Run Experiment"
	corner(self._btn, 6)
	self._btn.Parent = panel
	self._btn.Activated:Connect(function()
		self:_run()
	end)

	self._hint = Instance.new("TextLabel")
	self._hint.Position = UDim2.fromOffset(12, 82)
	self._hint.Size = UDim2.new(1, -24, 0, 16)
	self._hint.BackgroundTransparency = 1
	self._hint.Font = Enum.Font.Gotham
	self._hint.TextSize = 11
	self._hint.TextXAlignment = Enum.TextXAlignment.Left
	self._hint.TextColor3 = DIM
	self._hint.Text = ""
	self._hint.Parent = panel
end

-- Experiments collectable right now: an instrument on the craft, runnable here, not yet taken.
function ScienceController:_available()
	local out = {}
	local ctx = self._ctx
	if not ctx then
		return out, false
	end
	local hasInstrument = false
	local seen = {}
	for _, def in ipairs(self._vehicle:GetActiveParts()) do
		local expId = def.experiment
		if expId and not seen[expId] then
			seen[expId] = true
			hasInstrument = true
			if Science.canRun(expId, ctx) then
				local key = Science.key(expId, ctx.body, ctx.biome, ctx.situation)
				if not self._collected[key] then
					out[#out + 1] = { exp = expId, value = Science.value(expId, ctx.body, ctx.situation) }
				end
			end
		end
	end
	return out, hasInstrument
end

function ScienceController:_refresh()
	if not self._gui then
		return
	end
	local show = self._mode:GetMode() == "Flight"
	self._gui.Enabled = show
	if not show then
		return
	end

	local ctx = self._ctx
	if not ctx then
		self._sitLabel.Text = "--"
		self:_setButton(false, "Run Experiment")
		self._hint.Text = ""
		return
	end

	self._sitLabel.Text = ctx.body .. (ctx.biome and (" • " .. ctx.biome) or "") .. " • " .. ctx.situation

	local avail, hasInstrument = self:_available()
	local total = 0
	for _, a in ipairs(avail) do
		total += a.value
	end

	if #avail > 0 then
		self:_setButton(true, ("Run Experiment  (+%d)"):format(total))
		self._hint.Text = ("%d reading%s ready here"):format(#avail, #avail == 1 and "" or "s")
		self._hint.TextColor3 = SCI
	else
		self:_setButton(false, "Run Experiment")
		if not hasInstrument then
			self._hint.Text = "No instruments on craft"
		else
			self._hint.Text = "Nothing new to read here"
		end
		self._hint.TextColor3 = DIM
	end
end

function ScienceController:_setButton(active, text)
	self._btn.Text = text
	self._btn.Active = active
	self._btn.AutoButtonColor = active
	self._btn.BackgroundColor3 = active and GREEN or GREY
	self._btn.TextColor3 = active and Color3.fromRGB(255, 255, 255) or DIM
end

function ScienceController:_run()
	local ctx = self._ctx
	local avail = self:_available()
	if not ctx or #avail == 0 then
		return
	end
	local total = 0
	for _, a in ipairs(avail) do
		if self._runEv then
			self._runEv:FireServer({ exp = a.exp, body = ctx.body, biome = ctx.biome, situation = ctx.situation })
		end
		-- Optimistically mark collected so the button updates now; the State push confirms it.
		self._collected[Science.key(a.exp, ctx.body, ctx.biome, ctx.situation)] = true
		total += a.value
	end
	self:_flash(("+%d Science!"):format(total))
	self:_refresh()
end

function ScienceController:_flash(text)
	self._hint.Text = text
	self._hint.TextColor3 = SCI
	self._flashToken += 1
	local token = self._flashToken
	task.delay(2.5, function()
		if self._flashToken == token then
			self:_refresh()
		end
	end)
end

return ScienceController
