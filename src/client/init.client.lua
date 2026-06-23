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
	"TerrainController",
	"GameModeController",
	"VehicleController",
	"FloatingOriginController",
	"InputController",
	"FlightController",
	"CameraController",
	"PlanetRenderer",
	"MoonRenderer",
	"SunRenderer",
	"CraftRenderer",
	"SkyController",
	"CrewController",
	"MapViewController",
	"NavballController",
	"SoundController",
	"VABController",
	"StagingController",
	"HUDController",
	"MenuController",
}

-- Listeners must Start before the flight loop begins firing events.
-- CameraController starts before CraftRenderer so the planet proxy uses the
-- current frame's camera position.
local startOrder = {
	"TerrainController",
	"GameModeController",
	"VehicleController",
	"FloatingOriginController",
	"InputController",
	"CameraController",
	"PlanetRenderer",
	"MoonRenderer",
	"SunRenderer",
	"CraftRenderer",
	"SkyController",
	"CrewController",
	"MapViewController",
	"NavballController",
	"SoundController",
	"VABController",
	"StagingController",
	"HUDController",
	"MenuController",
	"FlightController",
}

local modules = {}
for _, name in ipairs(initOrder) do
	local mod = require(systemsFolder:WaitForChild(name))
	modules[name] = mod
	Registry:Register(name, mod)
end

-- Isolate per-module Init/Start failures so one bad module can't halt the rest.
for _, name in ipairs(initOrder) do
	local mod = modules[name]
	if type(mod.Init) == "function" then
		local ok, err = pcall(function()
			mod:Init()
		end)
		if not ok then
			warn(("[RocketSim] %s:Init() failed: %s"):format(name, tostring(err)))
		end
	end
end

for _, name in ipairs(startOrder) do
	local mod = modules[name]
	if type(mod.Start) == "function" then
		local ok, err = pcall(function()
			mod:Start()
		end)
		if not ok then
			warn(("[RocketSim] %s:Start() failed: %s"):format(name, tostring(err)))
		end
	end
end

print("[RocketSim] Client systems started -- 1.0.1 (Mun + SOI patched conics, no booster crossfeed, new parts/parachutes, icon staging chips).")
