--[[
	GameModeController
	Owner of: the current game mode ("VAB" while building, "Flight" while flying).

	Other systems read GetMode() and listen to ModeChanged. The B key (via
	InputController) and the VAB Launch button both route through SetMode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))

local GameModeController = {}

function GameModeController:Init()
	self._mode = "VAB"
	self.ModeChanged = Signal.new()
end

function GameModeController:Start()
	local Input = Registry:Get("InputController")
	Input:GetToggleModeSignal():Connect(function()
		self:SetMode(self._mode == "VAB" and "Flight" or "VAB")
	end)
end

function GameModeController:GetMode(): string
	return self._mode
end

function GameModeController:SetMode(mode: string)
	if mode == self._mode then
		return
	end
	self._mode = mode
	self.ModeChanged:Fire(mode)
end

return GameModeController
