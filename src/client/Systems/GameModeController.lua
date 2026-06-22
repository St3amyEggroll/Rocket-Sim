--[[
	GameModeController
	Owner of: the current game mode ("VAB" while building, "Flight" while flying).

	Other systems read GetMode() and listen to ModeChanged. The B key (via
	InputController) and the VAB Launch button both route through SetMode.

	ReturnToLaunch() is KSP's "Revert to Launch": it puts the craft back on the pad
	with a fresh fuel load. If we are already flying it fires LaunchReset (which
	FlightController turns into an in-place reset); from the VAB it just launches.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))

local GameModeController = {}

function GameModeController:Init()
	self._mode = "VAB"
	self.ModeChanged = Signal.new()
	self.LaunchReset = Signal.new() -- "revert to launch" while already in Flight
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

-- Back to the launch site (KSP "Revert to Launch"): reset the craft on the pad.
function GameModeController:ReturnToLaunch()
	if self._mode ~= "Flight" then
		self:SetMode("Flight") -- entering Flight already resets to the pad
	else
		self.LaunchReset:Fire() -- already flying: reset in place
	end
end

return GameModeController
