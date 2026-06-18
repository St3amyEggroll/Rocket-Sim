--[[
	Client bootstrap (LocalScript)
	StarterPlayer.StarterPlayerScripts.Client

	The anti-tangle entry point. It:
	  1. requires every system module and registers it by name,
	  2. runs ALL :Init() (no system touches another here),
	  3. runs ALL :Start() (systems wire themselves together via the Registry).

	Start order matters: FlightController starts LAST so the renderer, camera and
	HUD have already subscribed to its per-frame "Updated" signal before it
	begins firing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared:WaitForChild("Registry"))

local systemsFolder = script:WaitForChild("Systems")

-- The set of systems (require + register). Order here = Init order.
local initOrder = {
	"FloatingOriginController",
	"InputController",
	"FlightController",
	"CraftRenderer",
	"CameraController",
	"HUDController",
}

-- Listeners must Start before the flight loop begins firing events.
local startOrder = {
	"FloatingOriginController",
	"InputController",
	"CraftRenderer",
	"CameraController",
	"HUDController",
	"FlightController",
}

local modules = {}
for _, name in ipairs(initOrder) do
	local mod = require(systemsFolder:WaitForChild(name))
	modules[name] = mod
	Registry:Register(name, mod)
end

for _, name in ipairs(initOrder) do
	local mod = modules[name]
	if type(mod.Init) == "function" then
		mod:Init()
	end
end

for _, name in ipairs(startOrder) do
	local mod = modules[name]
	if type(mod.Start) == "function" then
		mod:Start()
	end
end

print("[RocketSim] Client systems started (Phase 1).")
