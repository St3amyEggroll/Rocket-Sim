--[[
	Server (Script)
	ServerScriptService.Server

	The flight sim runs entirely on the client. The player's avatar is shown as a
	client-side cosmetic rider on the craft (see CrewController), so the real
	server character is disabled - that avoids a physics character falling through
	our floating-origin world. Persistence (ProfileStore) comes in a later phase.
]]

local Players = game:GetService("Players")

-- No server-side physics character; the client renders a cosmetic rider instead.
Players.CharacterAutoLoads = false

-- Per-player tech progression (science + unlocked parts), persisted via DataStore.
local ok, err = pcall(function()
	require(script:WaitForChild("TechServer")).start()
end)
if not ok then
	warn("[RocketSim] TechServer failed to start: " .. tostring(err))
end

Players.PlayerAdded:Connect(function(player)
	print(("[RocketSim] %s joined."):format(player.Name))
end)

print("[RocketSim] Server ready -- build P2.5 (client-side flight sim + tech tree).")
