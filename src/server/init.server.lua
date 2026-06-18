--[[
	Server (Script)
	ServerScriptService.Server

	The flight sim runs entirely on the client. The player's avatar is shown as a
	client-side cosmetic rider on the craft (see CrewController), so the real
	server character is disabled - that avoids a physics character falling through
	our floating-origin world. Persistence (ProfileStore) comes in a later phase.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

-- No server-side physics character; the client renders a cosmetic rider instead.
Players.CharacterAutoLoads = false
Workspace.FallenPartsDestroyHeight = -1e9

Players.PlayerAdded:Connect(function(player)
	print(("[RocketSim] %s joined."):format(player.Name))
end)

print("[RocketSim] Server ready (client-side flight sim; persistence comes later).")
