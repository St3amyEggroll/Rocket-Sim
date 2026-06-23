--[[
	TerrainController
	Owner of: the HIGH-detail planet surface (real Roblox terrain). The always-
	visible low-detail body (the grass Ball) is owned by PlanetRenderer.

	Terrain is laid by RENDER DISTANCE around the CRAFT, not by generation and not
	by the camera. The planet's heightfield is fixed (Shared.Planet), and the world
	is divided into fixed cube CHUNKS. A chunk loads when it comes within
	Config.TERRAIN.renderDistance of the craft and unloads when it leaves; a chunk
	that is already loaded is never re-laid, so terrain that scrolls past you stays
	put rather than regenerating. Climb past streamOutAlt and every chunk unloads,
	leaving the Ball as the LOD.

	The floating origin is fixed at the body centre, so terrain world coordinates
	equal sim coordinates and the chunks line up with the heightfield exactly.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))

local TerrainController = {}

local AIR = Enum.Material.Air
local GRASS = Enum.Material.Grass

function TerrainController:Init()
	self._loaded = {} -- key -> chunk-centre Vector3 of terrain currently laid
	self._queue = {} -- ordered list of keys waiting to be filled
	self._queued = {} -- key -> true (membership of _queue)
	self._fillCount = 0 -- number of chunk-fill coroutines running
	self._present = false -- is any terrain currently laid?
	self._lastScan = 0
	self._chunkCount = 0
	self._gen = 0 -- bumped on a full clear; in-flight fills abort if it changes
end

function TerrainController:Start()
	local terrain = Workspace.Terrain
	terrain:Clear()
	pcall(function()
		terrain:SetMaterialColor(GRASS, Config.BODY.grassColor)
	end)

	local Flight = Registry:Get("FlightController")
	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_onUpdate(state, info)
	end)
end

-- Per-frame: keep the fill queue moving, and (throttled) rescan render distance.
function TerrainController:_onUpdate(state, info)
	self:_pump()

	local now = os.clock()
	if now - self._lastScan < Config.TERRAIN.scanInterval then
		return
	end
	self._lastScan = now

	-- Terra terrain only: when the craft is in the moon's SOI the sim state is
	-- moon-relative, so drop all Terra terrain (the moon is a smooth sphere).
	if info and info.bodyId and info.bodyId ~= "planet" then
		if self._present then
			self:_unloadAll()
		end
		return
	end
	self:_scan(state)
end

-- Decide which chunks should be loaded for the craft's current position.
function TerrainController:_scan(state)
	local T = Config.TERRAIN
	local R = Planet.seaLevel()
	local p = state.position
	local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local alt = r - R

	-- Coming in hot: start loading from higher up the faster you're DESCENDING, so the
	-- crust is ready before you arrive (horizontal orbit speed doesn't trigger this).
	local descent = 0
	if r > 1e-3 then
		local v = state.velocity
		descent = math.max(0, -(v.x * p.x + v.y * p.y + v.z * p.z) / r)
	end
	local streamIn = T.streamInAlt + (T.streamLeadFactor or 0) * descent
	local streamOut = math.max(T.streamOutAlt, streamIn + 400)

	-- Too high: drop everything, the Ball is the LOD.
	if alt > streamOut then
		if self._present then
			self:_unloadAll()
		end
		return
	end
	-- Hysteresis: only begin loading once we are below the (speed-scaled) stream-in altitude.
	if not self._present and alt > streamIn then
		return
	end

	local CS = T.chunkSize
	local ground = Vector3.new(p.x, p.y, p.z)
	ground = (ground.Magnitude > 1e-3) and ground.Unit * R or Vector3.new(0, R, 0)

	-- Build the desired chunk set: cubes that straddle the surface shell AND lie
	-- within renderDistance of the craft's ground point.
	local desired = {}
	local range = math.ceil(T.renderDistance / CS) + 1
	local base = Vector3.new(
		math.floor(ground.X / CS),
		math.floor(ground.Y / CS),
		math.floor(ground.Z / CS)
	)
	local shellBand = CS * 0.9 + Config.BIOMES.maxRelief
	local renderSq = T.renderDistance * T.renderDistance
	for dx = -range, range do
		for dy = -range, range do
			for dz = -range, range do
				local cx, cy, cz = base.X + dx, base.Y + dy, base.Z + dz
				local center = Vector3.new((cx + 0.5) * CS, (cy + 0.5) * CS, (cz + 0.5) * CS)
				if math.abs(center.Magnitude - R) <= shellBand then
					local off = center - ground
					if off.X * off.X + off.Y * off.Y + off.Z * off.Z <= renderSq then
						desired[cx .. "_" .. cy .. "_" .. cz] = center
					end
				end
			end
		end
	end

	-- Unload loaded chunks no longer desired.
	for key, center in pairs(self._loaded) do
		if not desired[key] then
			self:_unloadChunk(center)
			self._loaded[key] = nil
		end
	end
	-- Drop queued chunks no longer desired.
	for i = #self._queue, 1, -1 do
		local key = self._queue[i]
		if not desired[key] then
			table.remove(self._queue, i)
			self._queued[key] = nil
		end
	end
	-- Enqueue newly desired chunks (skip ones already laid or queued).
	for key, center in pairs(desired) do
		if not self._loaded[key] and not self._queued[key] then
			self._queue[#self._queue + 1] = key
			self._queued[key] = center
		end
	end

	self._chunkCount = 0
	for _ in pairs(self._loaded) do
		self._chunkCount += 1
	end
	self._present = self._chunkCount > 0 or #self._queue > 0
end

-- Start filling queued chunks, up to maxConcurrentFills at once (faster coverage).
function TerrainController:_pump()
	local maxFills = Config.TERRAIN.maxConcurrentFills or 1
	while self._fillCount < maxFills and #self._queue > 0 do
		local key = table.remove(self._queue, 1)
		local center = self._queued[key]
		self._queued[key] = nil
		if center then
			self._fillCount += 1
			task.spawn(function()
				local completed = self:_fillChunk(center, self._gen)
				if completed then
					self._loaded[key] = center
				end
				self._fillCount -= 1
			end)
		end
	end
end

-- Lay one chunk's terrain. For each grid cell we sample the biome surface and fill a
-- flat-topped COLUMN (an oriented FillBlock, top at the surface, crust deep, local up
-- = the surface normal). Roblox's terrain smoothing rounds adjacent columns into a
-- smooth surface (no visible spheres). We only fill cells whose surface point falls
-- inside THIS cube (ownership) so each chunk cleans up exactly what it placed.
function TerrainController:_fillChunk(center, gen)
	local T = Config.TERRAIN
	local terrain = Workspace.Terrain
	local spacing = T.spacing
	local crust = T.crustThickness
	local CS = T.chunkSize
	local R = Planet.seaLevel()

	local ox = math.floor(center.X / CS)
	local oy = math.floor(center.Y / CS)
	local oz = math.floor(center.Z / CS)

	local d = center.Unit
	local ref = (math.abs(d.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local t1 = d:Cross(ref).Unit
	local t2 = d:Cross(t1).Unit

	local boxSize = Vector3.new(T.footprint, crust, T.footprint)
	local half = CS * 0.8 -- sample a little past the cube so corners are covered
	local placed = 0
	for u = -half, half, spacing do
		for v = -half, half, spacing do
			local sd = (d * R + t1 * u + t2 * v).Unit
			local h, material = Planet.sample(sd.X, sd.Y, sd.Z)
			local p = sd * h -- surface point (oceans sit at sea level)
			if math.floor(p.X / CS) == ox and math.floor(p.Y / CS) == oy and math.floor(p.Z / CS) == oz then
				-- Oriented column: up = surface normal (sd), top at h, crust deep.
				local up = sd
				local rt = up:Cross(ref)
				rt = (rt.Magnitude > 1e-3) and rt.Unit or up:Cross(Vector3.xAxis).Unit
				terrain:FillBlock(CFrame.fromMatrix(sd * (h - crust * 0.5), rt, up), boxSize, material)
				placed += 1
				if placed % T.fillsPerYield == 0 then
					task.wait()
					if self._gen ~= gen then
						return false -- a full clear happened mid-fill; abort
					end
				end
			end
		end
	end
	return true
end

-- Clear one chunk's region. Inflated past the cube so fill-balls that spilled
-- across the faces are removed too (prevents orphan terrain being left behind).
function TerrainController:_unloadChunk(center)
	local T = Config.TERRAIN
	local pad = T.footprint + T.crustThickness + T.spacing
	local size = Vector3.new(T.chunkSize + pad, T.chunkSize + pad, T.chunkSize + pad)
	Workspace.Terrain:FillBlock(CFrame.new(center), size, AIR)
end

function TerrainController:_unloadAll()
	self._gen += 1 -- invalidate any in-flight chunk fill
	Workspace.Terrain:Clear()
	table.clear(self._loaded)
	table.clear(self._queue)
	table.clear(self._queued)
	self._chunkCount = 0
	self._present = false
end

-- For the debug overlay: which LOD is currently showing.
function TerrainController:GetLODState()
	if self._present then
		local q = #self._queue + self._fillCount
		if q > 0 then
			return string.format("crust: %d chunks (+%d loading)", self._chunkCount, q)
		end
		return string.format("crust: %d chunks", self._chunkCount)
	end
	return "Ball LOD (terrain unloaded)"
end

return TerrainController
