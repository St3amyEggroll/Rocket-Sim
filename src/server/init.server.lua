--[[
	Server (Script)
	ServerScriptService.Server

	The flight sim runs entirely on the client for responsiveness; the server
	handles the single-player setup now and will own persistence (ProfileStore:
	craft designs, progress, unlocks) in a later phase.

	The player's avatar rides the craft (see CrewController on the client), so
	characters are enabled and the void-cleanup height is pushed far away because
	the craft can travel far in sim space.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

Players.CharacterAutoLoads = true

-- The craft is kinematic and can roam; never auto-destroy parts for "falling".
Workspace.FallenPartsDestroyHeight = -1e9

Players.PlayerAdded:Connect(function(player)
	print(("[RocketSim] %s joined."):format(player.Name))
end)

print("[RocketSim] Server ready (Phase 2 - client-side flight sim; persistence comes later).")
