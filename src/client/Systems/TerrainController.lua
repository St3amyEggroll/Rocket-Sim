--[[
	TerrainController
	Owner of: the planet's appearance at two levels of detail.

	  * The LOW-detail body is a real grass Ball part (Planet.lodRadius()). It is a
	    genuine part (<=1024 radius), so it renders at any distance and never culls.
	    It is always present and is what you see from orbit.

	  * The HIGH-detail surface is real Roblox terrain laid by RENDER DISTANCE, not
	    generation. The planet's heightfield is fixed (Shared.Planet), and the world
	    is divided into fixed cube CHUNKS. A chunk loads when it comes within
	    Config.TERRAIN.renderDistance of the craft and unloads when it leaves;
	    a chunk that is already loaded is never re-laid, so terrain that scrolls past
	    you stays put rather than regenerating. Climb past streamOutAlt and every
	    chunk unloads, leaving the Ball as the LOD.

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
	self._filling = false -- a chunk fill coroutine is running
	self._present = false -- is any terrain currently laid?
	self._lastScan = 0
	self._chunkCount = 0
	self._gen = 0 -- bumped on a full clear; in-flight fills abort if it changes
end

function TerrainController:Start()
	self:_buildBody()

	local terrain = Workspace.Terrain
	terrain:Clear()
	pcall(function()
		terrain:SetMaterialColor(GRASS, Config.BODY.grassColor)
	end)

	local Flight = Registry:Get("FlightController")
	Flight:GetUpdatedSignal():Connect(function(state)
		self:_onUpdate(state)
	end)
end

-- The always-present low-detail body.
function TerrainController:_buildBody()
	local body = Config.BODY
	local lod = Planet.lodRadius()
	local planet = Instance.new("Part")
	planet.Name = "Planet"
	planet.Shape = Enum.PartType.Ball
	planet.Size = Vector3.new(lod * 2, lod * 2, lod * 2) -- <=2048 diameter: a real, never-culled part
	planet.Anchored = true
	planet.CanCollide = true
	planet.Color = body.grassColor
	planet.Material = GRASS
	planet.CFrame = CFrame.new(0, 0, 0)
	planet.Parent = Workspace
	self._planet = planet
end

-- Per-frame: keep the fill queue moving, and (throttled) rescan render distance.
function TerrainController:_onUpdate(state)
	self:_pump()

	local now = os.clock()
	if now - self._lastScan < Config.TERRAIN.scanInterval then
		return
	end
	self._lastScan = now
	self:_scan(state)
end

-- Decide which chunks should be loaded for the craft's current position.
function TerrainController:_scan(state)
	local T = Config.TERRAIN
	local R = Planet.seaLevel()
	local p = state.position
	local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	local alt = r - R

	-- Too high: drop everything, the Ball is the LOD.
	if alt > T.streamOutAlt then
		if self._present then
			self:_unloadAll()
		end
		return
	end
	-- Hysteresis: only begin loading once we are below streamInAlt.
	if not self._present and alt > T.streamInAlt then
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
	local shellBand = CS * 0.9 + T.reliefAmp
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

-- Start filling the next queued chunk if idle (one chunk at a time, frame-spread).
function TerrainController:_pump()
	if self._filling or #self._queue == 0 then
		return
	end
	local key = table.remove(self._queue, 1)
	local center = self._queued[key]
	self._queued[key] = nil
	if not center then
		return
	end
	self._filling = true
	task.spawn(function()
		local completed = self:_fillChunk(center, self._gen)
		if completed then
			self._loaded[key] = center
		end
		self._filling = false
	end)
end

-- Lay the curved crust for one chunk. We sample the heightfield over the chunk's
-- footprint on the sphere but only fill surface points that physically fall inside
-- THIS cube (ownership), so every ball a chunk places is removed by its own unload
-- (no orphans) and every surface point is owned by exactly one chunk (no holes).
-- Balls near a face still bridge into the neighbour cube, so there are no seams.
function TerrainController:_fillChunk(center, gen)
	local T = Config.TERRAIN
	local terrain = Workspace.Terrain
	local spacing = T.spacing
	local ballR = T.ballRadius
	local CS = T.chunkSize
	local R = Planet.seaLevel()

	-- This cube's integer cell (center = (cell + 0.5) * CS).
	local ox = math.floor(center.X / CS)
	local oy = math.floor(center.Y / CS)
	local oz = math.floor(center.Z / CS)

	local d = center.Unit
	local ref = (math.abs(d.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local t1 = d:Cross(ref).Unit
	local t2 = d:Cross(t1).Unit

	local half = CS * 0.8 -- sample a bit past the cube footprint so corners are covered
	local placed = 0
	for u = -half, half, spacing do
		for v = -half, half, spacing do
			local sd = (d * R + t1 * u + t2 * v).Unit
			local h = Planet.radiusForUnit(sd.X, sd.Y, sd.Z)
			local p = sd * h -- the surface point
			-- Only this chunk's own cells (the cube containing p).
			if math.floor(p.X / CS) == ox and math.floor(p.Y / CS) == oy and math.floor(p.Z / CS) == oz then
				-- Centre the fill-ball one radius below the surface so its top sits at h
				-- (matching where the craft lands) with the crust's thickness below it.
				terrain:FillBall(sd * (h - ballR), ballR, GRASS)
				placed += 1
				if placed % T.ballsPerYield == 0 then
					task.wait()
					-- A full clear (e.g. flew above streamOutAlt) happened mid-fill:
					-- abort so we do not lay orphan terrain over a cleared world.
					if self._gen ~= gen then
						return false
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
	local pad = T.ballRadius * 2 + T.spacing
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
		local q = #self._queue + (self._filling and 1 or 0)
		if q > 0 then
			return string.format("crust: %d chunks (+%d loading)", self._chunkCount, q)
		end
		return string.format("crust: %d chunks", self._chunkCount)
	end
	return "Ball LOD (terrain unloaded)"
end

return TerrainController
