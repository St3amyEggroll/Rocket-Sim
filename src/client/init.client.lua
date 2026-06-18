--[[
	Client bootstrap (LocalScript)
	StarterPlayer.StarterPlayerScripts.Client

	The anti-tangle entry point:
	  1. require every system module and register it by name,
	  2. run ALL :Init() (no system touches another here),
	  3. run ALL :Start() (systems wire themselves together via the Registry).

	FlightController starts LAST so the renderer, rider, map view, camera and HUD
	have already subscribed to its per-frame "Updated" signal before it fires.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared:WaitForChild("Registry"))

local systemsFolder = script:WaitForChild("Systems")

local initOrder = {
	"FloatingOriginController",
	"InputController",
	"FlightController",
	"CraftRenderer",
	"CrewController",
	"MapViewController",
	"CameraController",
	"HUDController",
}

-- Listeners must Start before the flight loop begins firing events.
local startOrder = {
	"FloatingOriginController",
	"InputController",
	"CraftRenderer",
	"CrewController",
	"MapViewController",
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

print("[RocketSim] Client systems started -- build P2.4 (rocket+planet, cached map, small world).")
