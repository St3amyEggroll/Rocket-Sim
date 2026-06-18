--[[
	Server (Script)
	ServerScriptService.Server

	Phase 1 server responsibilities are intentionally tiny: the flight sim runs
	entirely on the client for responsiveness, so the server only sets up the
	single-player feel. Persistence (ProfileStore: craft designs, progress,
	unlocks) and progression validation arrive in later phases.
]]

local Players = game:GetService("Players")

-- No walking avatar: the player only ever flies a craft, and the client owns a
-- Scriptable camera. Disabling auto character load keeps Roblox rigid-body
-- physics and the default humanoid camera out of the way entirely.
Players.CharacterAutoLoads = false

Players.PlayerAdded:Connect(function(player)
	print(("[RocketSim] %s joined."):format(player.Name))
end)

print("[RocketSim] Server ready (Phase 1 - client-side flight sim; persistence comes later).")
