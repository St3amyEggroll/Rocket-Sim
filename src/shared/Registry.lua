--[[
	Registry
	ReplicatedStorage.Shared.Registry

	A tiny service locator so systems can find each other by name at runtime
	(Start / per-frame) instead of require-ing each other at the top of the file.
	This is what keeps the module graph from tangling.

	Each Lua VM (the client, the server) gets its own registry because a
	required ModuleScript is cached per side.
]]

local Registry = {}

local items: { [string]: any } = {}

function Registry:Register(name: string, obj: any): any
	assert(type(name) == "string", "Registry:Register expects a string name")
	if items[name] ~= nil then
		warn(("[Registry] '%s' is being overwritten"):format(name))
	end
	items[name] = obj
	return obj
end

function Registry:Get(name: string): any
	local obj = items[name]
	if obj == nil then
		error(("[Registry] nothing registered as '%s'"):format(tostring(name)), 2)
	end
	return obj
end

function Registry:GetOrNil(name: string): any
	return items[name]
end

return Registry
