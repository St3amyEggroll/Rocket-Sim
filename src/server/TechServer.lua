--[[
	TechServer
	Per-player tech progress (science + unlocked tiers), persisted via DataStore and synced
	to the client over RemoteEvents in ReplicatedStorage.TechRemotes.

	The flight sim is client-side, so milestone reports are trusted; the server still
	validates unlock costs + the tier-ladder order. All DataStore calls are pcall-guarded --
	if the store is unavailable (e.g. Studio without API access) progress is session-only.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TechTree = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TechTree"))

local TechServer = {}

local KEY_PREFIX = "tech_v1_"
local store
local remotes
local data = {} -- [userId] = { science, unlocked = {tierId=true}, milestones = {id=true} }

local function defaultProfile()
	return { science = 0, unlocked = { basics = true }, milestones = {} }
end

local function push(player)
	local prof = data[player.UserId]
	if prof and remotes then
		remotes.state:FireClient(player, prof)
	end
end

local function load(player)
	local prof = defaultProfile()
	if store then
		local ok, saved = pcall(function()
			return store:GetAsync(KEY_PREFIX .. player.UserId)
		end)
		if ok and type(saved) == "table" then
			prof.science = tonumber(saved.science) or 0
			prof.unlocked = (type(saved.unlocked) == "table") and saved.unlocked or { basics = true }
			prof.unlocked.basics = true -- always available
			prof.milestones = (type(saved.milestones) == "table") and saved.milestones or {}
		end
	end
	data[player.UserId] = prof
end

local function save(player)
	local prof = data[player.UserId]
	if store and prof then
		pcall(function()
			store:SetAsync(KEY_PREFIX .. player.UserId, prof)
		end)
	end
end

local function onReportMilestone(player, milestoneId)
	local prof = data[player.UserId]
	if not prof or type(milestoneId) ~= "string" or prof.milestones[milestoneId] then
		return
	end
	local science = TechTree.milestoneScience(milestoneId)
	if not science then
		return
	end
	prof.milestones[milestoneId] = true
	prof.science += science
	save(player)
	push(player)
end

local function onUnlockTier(player, tierId)
	local prof = data[player.UserId]
	if not prof or type(tierId) ~= "string" or prof.unlocked[tierId] then
		return
	end
	local tier = TechTree.tierById(tierId)
	if not tier then
		return
	end
	-- Ladder rule: the previous tier must already be unlocked.
	local prev = TechTree.prevTierId(tierId)
	if prev and not prof.unlocked[prev] then
		return
	end
	if prof.science < tier.cost then
		return
	end
	prof.science -= tier.cost
	prof.unlocked[tierId] = true
	save(player)
	push(player)
end

function TechServer.start()
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("RocketSimTech")
	end)
	store = ok and ds or nil
	if not store then
		warn("[RocketSim] Tech DataStore unavailable -- progress is session-only.")
	end

	local folder = Instance.new("Folder")
	folder.Name = "TechRemotes"
	local stateEv = Instance.new("RemoteEvent")
	stateEv.Name = "State"
	stateEv.Parent = folder
	local reportEv = Instance.new("RemoteEvent")
	reportEv.Name = "ReportMilestone"
	reportEv.Parent = folder
	local unlockEv = Instance.new("RemoteEvent")
	unlockEv.Name = "UnlockTier"
	unlockEv.Parent = folder
	folder.Parent = ReplicatedStorage
	remotes = { state = stateEv, report = reportEv, unlock = unlockEv }

	reportEv.OnServerEvent:Connect(onReportMilestone)
	unlockEv.OnServerEvent:Connect(onUnlockTier)
	-- A client can fire State (no args) to (re)request its profile -- covers late joins.
	stateEv.OnServerEvent:Connect(function(player)
		if data[player.UserId] then
			push(player)
		end
	end)

	local function added(player)
		load(player)
		push(player)
	end
	Players.PlayerAdded:Connect(added)
	for _, player in ipairs(Players:GetPlayers()) do
		added(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player)
		data[player.UserId] = nil
	end)
end

return TechServer
