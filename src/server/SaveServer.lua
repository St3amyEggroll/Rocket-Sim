--[[
	SaveServer
	Per-player SAVE SLOTS, persisted via DataStore and synced to the client over
	ReplicatedStorage.GameRemotes.

	Each player has SLOTS (1..MAX_SLOTS). A slot holds one "profile" = the whole game save:
	science, unlocked tech tiers, earned milestones, and (room reserved) the craft design and
	in-orbit vessels. The client picks a slot at the menu; that slot becomes ACTIVE and all
	progress (milestones, unlocks, craft saves) reads/writes it, persisting to DataStore.

	The flight sim is client-side, so milestone reports are trusted; the server still
	validates unlock cost + tier order. All DataStore calls are pcall-guarded -- if the store
	is unavailable (e.g. Studio without API access) saves are session-only.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TechTree = require(Shared:WaitForChild("TechTree"))
local Science = require(Shared:WaitForChild("Science"))

local SaveServer = {}

local MAX_SLOTS = 3
local MAX_VESSELS = 4
local store
local remotes
local active = {} -- [userId] = slot number currently loaded (nil = none)
local profiles = {} -- [userId] = the active profile table

local function slotKey(userId, slot)
	return ("save_v1_%d_%d"):format(userId, slot)
end

local function defaultProfile(name)
	return {
		name = name or "New Save",
		updated = 0,
		science = 0,
		unlocked = { basics = true },
		milestones = {},
		experiments = {}, -- collected biome/situation science keys (Science.key -> true)
		craft = nil, -- reserved: serialized build-mode design
		vessels = {}, -- reserved: in-orbit craft (for docking)
	}
end

local function normalize(p)
	p.science = tonumber(p.science) or 0
	p.unlocked = (type(p.unlocked) == "table") and p.unlocked or {}
	p.unlocked.basics = true
	p.milestones = (type(p.milestones) == "table") and p.milestones or {}
	p.experiments = (type(p.experiments) == "table") and p.experiments or {}
	p.vessels = (type(p.vessels) == "table") and p.vessels or {}
	return p
end

local function readSlot(userId, slot)
	if not store then
		return nil
	end
	local ok, data = pcall(function()
		return store:GetAsync(slotKey(userId, slot))
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

local function writeSlot(userId, slot, profile)
	if not store then
		return
	end
	pcall(function()
		store:SetAsync(slotKey(userId, slot), profile)
	end)
end

local function pushState(player)
	local p = profiles[player.UserId]
	if p and remotes then
		remotes.state:FireClient(player, p)
	end
end

local function saveActive(player)
	local uid = player.UserId
	if active[uid] and profiles[uid] then
		profiles[uid].updated = os.time()
		writeSlot(uid, active[uid], profiles[uid])
	end
end

-- ---- RemoteFunction handlers (menu) ----

local function onList(player)
	local uid = player.UserId
	local out = {}
	for slot = 1, MAX_SLOTS do
		local data = readSlot(uid, slot)
		if data then
			out[slot] =
				{ slot = slot, empty = false, name = data.name or ("Save " .. slot), science = data.science or 0, updated = data.updated or 0 }
		else
			out[slot] = { slot = slot, empty = true }
		end
	end
	return out
end

local function onLoad(player, slot)
	if type(slot) ~= "number" then
		return false
	end
	local uid = player.UserId
	local data = readSlot(uid, slot)
	if not data then
		return false
	end
	profiles[uid] = normalize(data)
	active[uid] = slot
	pushState(player)
	return true
end

local function onNew(player, slot, name)
	if type(slot) ~= "number" or slot < 1 or slot > MAX_SLOTS then
		return false
	end
	local uid = player.UserId
	profiles[uid] = defaultProfile(type(name) == "string" and name ~= "" and name or ("Save " .. slot))
	active[uid] = slot
	saveActive(player)
	pushState(player)
	return true
end

local function onDelete(player, slot)
	if type(slot) ~= "number" then
		return false
	end
	local uid = player.UserId
	if store then
		pcall(function()
			store:RemoveAsync(slotKey(uid, slot))
		end)
	end
	if active[uid] == slot then
		active[uid] = nil
		profiles[uid] = nil
	end
	return true
end

-- ---- RemoteEvent handlers (gameplay) ----

local function onReportMilestone(player, milestoneId)
	local p = profiles[player.UserId]
	if not p or type(milestoneId) ~= "string" or p.milestones[milestoneId] then
		return
	end
	local science = TechTree.milestoneScience(milestoneId)
	if not science then
		return
	end
	p.milestones[milestoneId] = true
	p.science += science
	saveActive(player)
	pushState(player)
end

local function onUnlockTier(player, nodeId)
	local p = profiles[player.UserId]
	if not p or type(nodeId) ~= "string" or p.unlocked[nodeId] then
		return
	end
	local node = TechTree.nodeById(nodeId)
	if not node then
		return
	end
	-- Buyable only once a prerequisite is researched (branching graph), and you can afford it.
	if not TechTree.requiresMet(node, p.unlocked) then
		return
	end
	if p.science < node.cost then
		return
	end
	p.science -= node.cost
	p.unlocked[nodeId] = true
	saveActive(player)
	pushState(player)
end

-- Biome/situation science: grant the reading's value once per { experiment, body, biome,
-- situation } key. The flight sim is client-side, so the situation report is trusted; the
-- server still owns the value (shared Science table) and the one-time dedup.
local function onRunExperiment(player, report)
	local p = profiles[player.UserId]
	if not p or type(report) ~= "table" then
		return
	end
	local expId, body, situation, biome = report.exp, report.body, report.situation, report.biome
	if type(expId) ~= "string" or type(body) ~= "string" or type(situation) ~= "string" then
		return
	end
	if biome ~= nil and type(biome) ~= "string" then
		return
	end
	local value = Science.value(expId, body, situation)
	if value <= 0 then
		return
	end
	local key = Science.key(expId, body, biome, situation)
	p.experiments = p.experiments or {}
	if p.experiments[key] then
		return -- already collected this reading
	end
	p.experiments[key] = true
	p.science += value
	saveActive(player)
	pushState(player)
end

local function num(v)
	return (type(v) == "number" and v == v) and v or 0 -- coerce; reject NaN
end

-- Leave a craft in orbit: store it as a persistent vessel (orbital state relative to its body +
-- a lightweight design) that the player can rendezvous/dock with on later flights.
local function onSaveVessel(player, vessel)
	local p = profiles[player.UserId]
	if not p or type(vessel) ~= "table" then
		return
	end
	if type(vessel.pos) ~= "table" or type(vessel.vel) ~= "table" or type(vessel.design) ~= "table" then
		return
	end
	p.vessels = p.vessels or {}
	local clean = {
		name = (type(vessel.name) == "string" and vessel.name ~= "" and vessel.name) or ("Vessel " .. (#p.vessels + 1)),
		bodyId = (type(vessel.bodyId) == "string") and vessel.bodyId or "planet",
		pos = { x = num(vessel.pos.x), y = num(vessel.pos.y), z = num(vessel.pos.z) },
		vel = { x = num(vessel.vel.x), y = num(vessel.vel.y), z = num(vessel.vel.z) },
		design = vessel.design,
	}
	table.insert(p.vessels, clean)
	while #p.vessels > MAX_VESSELS do
		table.remove(p.vessels, 1)
	end
	saveActive(player)
	pushState(player)
end

local function onDeleteVessel(player, index)
	local p = profiles[player.UserId]
	if not p or type(index) ~= "number" or not p.vessels then
		return
	end
	if p.vessels[index] then
		table.remove(p.vessels, index)
		saveActive(player)
		pushState(player)
	end
end

-- Save the current craft design into the active slot (reserved for the craft serializer).
local function onSaveCraft(player, craft)
	local p = profiles[player.UserId]
	if not p then
		return
	end
	p.craft = craft
	saveActive(player)
end

function SaveServer.start()
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("RocketSimSaves")
	end)
	store = ok and ds or nil
	if not store then
		warn("[RocketSim] Save DataStore unavailable -- saves are session-only.")
	end

	local folder = Instance.new("Folder")
	folder.Name = "GameRemotes"
	local function rf(name)
		local f = Instance.new("RemoteFunction")
		f.Name = name
		f.Parent = folder
		return f
	end
	local function re(name)
		local e = Instance.new("RemoteEvent")
		e.Name = name
		e.Parent = folder
		return e
	end
	local listFn, loadFn, newFn, delFn = rf("ListSaves"), rf("LoadSave"), rf("NewGame"), rf("DeleteSave")
	local stateEv, reportEv, unlockEv, craftEv = re("State"), re("ReportMilestone"), re("UnlockTier"), re("SaveCraft")
	local experimentEv = re("RunExperiment")
	local saveVesselEv, delVesselEv = re("SaveVessel"), re("DeleteVessel")
	folder.Parent = ReplicatedStorage
	remotes = { state = stateEv }

	listFn.OnServerInvoke = onList
	loadFn.OnServerInvoke = onLoad
	newFn.OnServerInvoke = onNew
	delFn.OnServerInvoke = onDelete
	reportEv.OnServerEvent:Connect(onReportMilestone)
	unlockEv.OnServerEvent:Connect(onUnlockTier)
	craftEv.OnServerEvent:Connect(onSaveCraft)
	experimentEv.OnServerEvent:Connect(onRunExperiment)
	saveVesselEv.OnServerEvent:Connect(onSaveVessel)
	delVesselEv.OnServerEvent:Connect(onDeleteVessel)
	stateEv.OnServerEvent:Connect(function(player)
		pushState(player) -- client re-request (covers a late client)
	end)

	Players.PlayerRemoving:Connect(function(player)
		saveActive(player)
		active[player.UserId] = nil
		profiles[player.UserId] = nil
	end)
	game:BindToClose(function()
		for _, player in ipairs(Players:GetPlayers()) do
			saveActive(player)
		end
	end)
end

return SaveServer
