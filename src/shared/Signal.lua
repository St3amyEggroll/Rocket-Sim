--[[
	Signal
	ReplicatedStorage.Shared.Signal

	A minimal synchronous signal. Handlers fire in connection order, which lets
	one owner module broadcast a per-frame "Updated" event that listeners
	(renderer, camera, HUD) react to in a deterministic sequence.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = { Disconnect: (any) -> () }

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local conn = { fn = fn, connected = true }
	table.insert(self._handlers, conn)

	local handlers = self._handlers
	return {
		Disconnect = function()
			if not conn.connected then
				return
			end
			conn.connected = false
			for i = #handlers, 1, -1 do
				if handlers[i] == conn then
					table.remove(handlers, i)
					break
				end
			end
		end,
	}
end

function Signal:Fire(...)
	local handlers = self._handlers
	for i = 1, #handlers do
		local conn = handlers[i]
		if conn and conn.connected then
			conn.fn(...)
		end
	end
end

function Signal:Destroy()
	table.clear(self._handlers)
end

return Signal
