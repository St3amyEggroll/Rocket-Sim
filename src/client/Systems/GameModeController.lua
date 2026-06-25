--[[
	GameModeController
	Owner of: the current game STATE.

	Menu states (front-end, no gameplay): "MainMenu", "Settings", "ModeSelect", "SaveSelect".
	In-game states: "VAB" (build), "Research" (tech tree), "Flight" (flying).

	Other systems read GetMode() and listen to ModeChanged. The B key toggles VAB<->Flight
	in-game; the top nav bar switches Build/Research/Launch; the front-end (MenuFlowController)
	drives the menu states and enters the game (-> VAB) once a save is loaded.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))

local GameModeController = {}

local MENU_STATES = { MainMenu = true, Settings = true, ModeSelect = true, SaveSelect = true }

function GameModeController:Init()
	self._mode = "MainMenu"
	self.ModeChanged = Signal.new()
	self.LaunchReset = Signal.new() -- "revert to launch" while already in Flight
end

function GameModeController:Start()
	local Input = Registry:Get("InputController")
	self._vehicle = Registry:Get("VehicleController")
	Input:GetToggleModeSignal():Connect(function()
		-- B only toggles build<->flight while in the game (ignored in menus / research).
		if self._mode == "VAB" then
			-- Can't fly an uncontrolled stack: a command pod (or probe core) is required.
			if self._vehicle and not self._vehicle:HasControl() then
				return
			end
			self:SetMode("Flight")
		elseif self._mode == "Flight" then
			self:SetMode("VAB")
		end
	end)
end

function GameModeController:GetMode(): string
	return self._mode
end

function GameModeController:IsMenu(): boolean
	return MENU_STATES[self._mode] == true
end

function GameModeController:IsInGame(): boolean
	return MENU_STATES[self._mode] ~= true
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
