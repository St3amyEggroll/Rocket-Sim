--[[
	VehicleController
	Owner of: the active craft design AND its flight-time runtime (staging, fuel).
	Single source of truth for "what the rocket is".

	KSP-style 3D assembly: the design is a SET OF PARTS placed in 3D build space, each
	with an id, its definition, a build-local CFrame, the index of the part it is
	attached to (parent; nil for the root), and a STAGE number (which firing it belongs
	to). Build space has +Y up (the nose direction) and its origin at the launch pad.

	Staging is a real KSP-style model -- not a fixed serial list:
	  * Parts are grouped into FUEL SECTIONS: connected runs of tanks/engines, CUT at
	    every decoupler (decouplers block crossfeed). Engines burn from their own
	    section, so side boosters carry their own fuel and the core carries its own.
	  * Each engine and decoupler is assigned a STAGE. Firing a stage IGNITES that
	    stage's engines (several at once = parallel boosters) and SEPARATES that stage's
	    decouplers. Whatever is no longer connected to the command pod drops away.
	  * The ACTIVE set is recomputed from the connectivity each time the stage advances.

	Flight reads net thrust + the thrust torque from off-axis engines, burns each
	section's fuel, and measures mass / CoM / inertia from the parts still attached.
	GetFlightOffset re-centres the assembly (base on the pad, CoM on the thrust axis)
	for the renderer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))

local VehicleController = {}

local function isDecoupler(def)
	return def ~= nil and def.decoupler == true
end
local function isEngine(def)
	return def ~= nil and def.category == "engine"
end
-- An "actuator" is a part that does something when its stage fires (ignite engine /
-- separate decoupler / deploy parachute).
local function isActuator(def)
	return isEngine(def) or isDecoupler(def) or (def ~= nil and def.parachute == true)
end

function VehicleController:Init()
	self._surfaceGravity = Config.BODY.mu / (Config.BODY.radius * Config.BODY.radius)
	self.Changed = Signal.new()
	self.Staged = Signal.new() -- fires (droppedGroups) just before Changed on a stage

	self._editing = true -- VAB shows the whole craft; flight runs the staging sim
	self._autoStage = true -- auto-assign stages until the player edits the staging panel
	self._stageFloor = 0 -- lowest number of stages (the panel can add empty ones)
	self._nextSymId = 1 -- ids shared by parts placed together as a symmetry set
	self._runtimeVer = 0 -- bumped whenever mass/active-set/fuel changes (caches key off it)

	-- Default rocket: stack the default design vertically (bottom -> top) in build space.
	self._parts = {}
	local y = 0
	local prev = nil
	for _, id in ipairs(Config.LAUNCH.defaultDesign) do
		local def = Catalog.get(id)
		if def then
			local h = def.height or 0
			table.insert(self._parts, { id = id, def = def, cf = CFrame.new(0, y + h * 0.5, 0), parent = prev })
			prev = #self._parts
			y += h
		end
	end

	self._stageIndex = 1
	self:_recompute()
end

function VehicleController:Start()
	local mode = Registry:Get("GameModeController")
	self._editing = (mode:GetMode() == "VAB")
	mode.ModeChanged:Connect(function(m)
		self._editing = (m == "VAB")
		self:_computeActive()
		self.Changed:Fire()
	end)
end

-- Bottom of a part along the build axis (used to order the stack + default staging).
function VehicleController:_partBottom(part)
	return part.cf.Y - (part.def.height or 0) * 0.5
end

-- ---------------------------------------------------------------- recompute ----

function VehicleController:_recompute()
	local parts = self._parts

	-- Order the parts bottom -> top (stable: ties keep insertion order). Used for layout
	-- and for default staging.
	local order = {}
	for i = 1, #parts do
		order[i] = i
	end
	table.sort(order, function(a, b)
		local ba, bb = self:_partBottom(parts[a]), self:_partBottom(parts[b])
		if ba == bb then
			return a < b
		end
		return ba < bb
	end)
	self._order = order

	self:_computeSections()
	self._keepRoot = self:_findKeepRoot()
	self:_assignStages()
	self._stageCount = self:_maxStage()
	self._stats = self:_computeStats()

	self:ResetRuntime()
end

-- Fuel sections: connected components of the part graph (parent links), CUT at every
-- decoupler (a decoupler conducts no fuel). Each engine burns from its section.
function VehicleController:_computeSections()
	local parts = self._parts
	local uf = {}
	for i = 1, #parts do
		uf[i] = i
	end
	local function find(x)
		while uf[x] ~= x do
			uf[x] = uf[uf[x]]
			x = uf[x]
		end
		return x
	end
	for i, p in ipairs(parts) do
		local pr = p.parent
		-- Fuel conducts only through STACK (node) joints -- never across a surface/radial
		-- attachment or a decoupler -- so side boosters keep their own fuel and don't feed
		-- (or drain) the core.
		if pr and parts[pr] and not p.surface and not isDecoupler(p.def) and not isDecoupler(parts[pr].def) then
			local ri, rp = find(i), find(pr)
			if ri ~= rp then
				uf[ri] = rp
			end
		end
	end
	local sectionOf, capacity = {}, {}
	for i, p in ipairs(parts) do
		if not isDecoupler(p.def) then
			local root = find(i)
			sectionOf[i] = root
			capacity[root] = (capacity[root] or 0) + (p.def.fuel or 0)
		end
	end
	-- Radial-mount engines carry no tank: they draw from the part they're bolted to.
	for i, p in ipairs(parts) do
		if isEngine(p.def) and p.def.radial and p.parent and sectionOf[p.parent] then
			sectionOf[i] = sectionOf[p.parent]
		end
	end
	self._sectionOf = sectionOf
	self._sectionCapacity = capacity
end

-- The part that keeps flying: the command pod, else the topmost non-decoupler part.
function VehicleController:_findKeepRoot()
	local parts = self._parts
	for i, p in ipairs(parts) do
		if p.def.category == "command" then
			return i
		end
	end
	local best, bi = -math.huge, nil
	for i, p in ipairs(parts) do
		if not isDecoupler(p.def) and p.cf.Y > best then
			best, bi = p.cf.Y, i
		end
	end
	return bi or (parts[1] and 1 or nil)
end

-- Assign each actuator a stage. While auto (the player hasn't touched staging) the
-- stages track the build, bottom -> top. Once edited, existing stages are preserved
-- and only brand-new actuators get a sensible default.
function VehicleController:_assignStages()
	local parts = self._parts
	local acts = {}
	for i, p in ipairs(parts) do
		if isActuator(p.def) then
			acts[#acts + 1] = { i = i, y = self:_partBottom(p) }
		end
	end
	table.sort(acts, function(a, b)
		if a.y == b.y then
			return a.i < b.i
		end
		return a.y < b.y
	end)

	if self._autoStage then
		for rank, a in ipairs(acts) do
			parts[a.i].stage = rank
		end
	else
		for _, a in ipairs(acts) do
			if not parts[a.i].stage then
				local rank = 1
				for _, b in ipairs(acts) do
					if b.y < a.y then
						rank += 1
					end
				end
				parts[a.i].stage = rank
			end
		end
	end
end

function VehicleController:_maxStage()
	local m = 0
	for _, p in ipairs(self._parts) do
		if isActuator(p.def) and p.stage and p.stage > m then
			m = p.stage
		end
	end
	return math.max(m, self._stageFloor or 0)
end

-- Per-stage delta-v / mass / TWR estimate for the VAB readout. Treats each engine
-- section as a serial burn in ignition order (a good estimate for the readout; the
-- flight loop itself runs the exact per-frame model).
function VehicleController:_computeStats()
	local parts = self._parts

	local totalMass = 0
	for _, p in ipairs(parts) do
		totalMass += (p.def.mass or 0) + (p.def.fuel or 0)
	end

	-- Gather engine sections: fuel, dry mass, a thrust-weighted ve, ignition stage, and
	-- whether a decoupler can ever drop them (so their dry mass leaves after burning).
	local sections = {}
	for i, p in ipairs(parts) do
		local sec = self._sectionOf[i]
		if sec then
			local s = sections[sec]
			if not s then
				s = { fuel = 0, dry = 0, thrust = 0, veSum = 0, ignite = math.huge, droppable = false, hasEngine = false }
				sections[sec] = s
			end
			s.dry += p.def.mass or 0
			s.fuel += p.def.fuel or 0
			if isEngine(p.def) then
				s.hasEngine = true
				s.thrust += p.def.thrust or 0
				s.veSum += (p.def.thrust or 0) * (p.def.exhaustVelocity or 0)
				s.ignite = math.min(s.ignite, p.stage or math.huge)
			end
			if sec == self._sectionOf[self._keepRoot or -1] then
				s.keep = true
			end
		end
	end
	-- A section is droppable if a decoupler touches it and it isn't the keep section.
	for i, p in ipairs(parts) do
		if isDecoupler(p.def) then
			local pr = p.parent
			if pr and self._sectionOf[pr] and sections[self._sectionOf[pr]] then
				sections[self._sectionOf[pr]].droppable = true
			end
			for j, q in ipairs(parts) do
				if q.parent == i and self._sectionOf[j] and sections[self._sectionOf[j]] then
					sections[self._sectionOf[j]].droppable = true
				end
			end
		end
	end

	-- Burn order: by ignition stage; the keep section always burns last.
	local burn = {}
	for _, s in pairs(sections) do
		if s.hasEngine and s.fuel > 0 then
			burn[#burn + 1] = s
		end
	end
	table.sort(burn, function(a, b)
		if a.keep ~= b.keep then
			return not a.keep
		end
		return (a.ignite or 0) < (b.ignite or 0)
	end)

	local totalDV, stageCount = 0, 0
	local mCur = totalMass
	for _, s in ipairs(burn) do
		local ve = (s.thrust > 0) and (s.veSum / s.thrust) or 0
		local m0 = mCur
		local mf = mCur - s.fuel
		if ve > 0 and mf > 0 then
			totalDV += ve * math.log(m0 / mf)
			stageCount += 1
		end
		mCur = mf
		if s.droppable and not s.keep then
			mCur -= s.dry -- the spent section drops, lightening later stages
		end
	end

	-- Launch TWR: thrust of the engines that ignite in stage 1.
	local launchThrust = 0
	for _, p in ipairs(parts) do
		if isEngine(p.def) and (p.stage or math.huge) <= 1 then
			launchThrust += p.def.thrust or 0
		end
	end
	local launchTWR = 0
	if launchThrust > 0 and self._surfaceGravity > 0 and totalMass > 0 then
		launchTWR = launchThrust / (totalMass * self._surfaceGravity)
	end

	return {
		stageCount = math.max(stageCount, self._stageCount or 0),
		totalMass = totalMass,
		totalDeltaV = totalDV,
		launchTWR = launchTWR,
	}
end

-- ---- Design editing (VAB) ----

-- Place a part at a build-local CFrame, attached to `parent` (a part index or nil for
-- the root). Returns the new part's index.
-- Raw insert (no recompute). symId/symIndex tag a part as a member of a symmetry set.
function VehicleController:_appendPart(id, cf, parent, surface, symId, symIndex)
	local def = Catalog.get(id)
	if not def then
		return nil
	end
	table.insert(self._parts, {
		id = id,
		def = def,
		cf = cf,
		parent = parent,
		surface = surface or false,
		symId = symId,
		symIndex = symIndex,
	})
	return #self._parts
end

function VehicleController:AddPartAt(id, cf, parent, surface, symId)
	local idx = self:_appendPart(id, cf, parent, surface, symId, nil)
	if idx then
		self:_recompute()
	end
	return idx
end

function VehicleController:NewSymId()
	local id = self._nextSymId
	self._nextSymId += 1
	return id
end

-- The symmetry set a part belongs to: a sorted list of { index, symIndex } (the part
-- itself if it has no group).
function VehicleController:GetSymGroup(index)
	local p = self._parts[index]
	local out = {}
	if p and p.symId then
		for i, q in ipairs(self._parts) do
			if q.symId == p.symId then
				out[#out + 1] = { index = i, symIndex = q.symIndex or 0 }
			end
		end
		table.sort(out, function(a, b)
			return a.symIndex < b.symIndex
		end)
	else
		out[1] = { index = index, symIndex = 0 }
	end
	return out
end

function VehicleController:GetSymGroupSize(index)
	local p = self._parts[index]
	if not p or not p.symId then
		return 1
	end
	local n = 0
	for _, q in ipairs(self._parts) do
		if q.symId == p.symId then
			n += 1
		end
	end
	return n
end

-- A part plus all its descendants (parents listed before children), by part index.
function VehicleController:GetSubtree(index)
	local out = { index }
	local seen = { [index] = true }
	local changed = true
	while changed do
		changed = false
		for i, p in ipairs(self._parts) do
			if not seen[i] and p.parent and seen[p.parent] then
				seen[i] = true
				out[#out + 1] = i
				changed = true
			end
		end
	end
	return out
end

-- The lateral axis (x,z) of a part's root ancestor -- the core to mirror symmetry around.
function VehicleController:GetRootAxis(index)
	local p = self._parts[index]
	local guard = 0
	while p and p.parent and self._parts[p.parent] and guard < 4096 do
		index = p.parent
		p = self._parts[index]
		guard += 1
	end
	if p then
		return { x = p.cf.X, z = p.cf.Z }
	end
	return { x = 0, z = 0 }
end

-- Remove a SET of parts ({ [index]=true }) at once, repairing parent links. Returns a
-- remap (oldIndex -> newIndex) for the survivors.
function VehicleController:RemoveParts(indexSet)
	local newParts, remap = {}, {}
	for i, p in ipairs(self._parts) do
		if not indexSet[i] then
			newParts[#newParts + 1] = p
			remap[i] = #newParts
		end
	end
	for _, p in ipairs(newParts) do
		if p.parent then
			p.parent = remap[p.parent] -- nil if the parent was removed
		end
	end
	self._parts = newParts
	self:_recompute()
	return remap
end

-- Add a UNIT (a blueprint of a part + its subtree, relative to the root) rotated by
-- `angle` about `axis`(x,z) and positioned at rootPos. The root parents to `rootParent`
-- and takes `rootSurface`/`symId`/`symIndex`; the subtree reconstructs its own links.
function VehicleController:_addUnitCopy(blueprint, rootPos, rootParent, rootSurface, axis, angle, symId, symIndex)
	local ca, sa = math.cos(angle), math.sin(angle)
	local function rotY(vx, vz)
		return vx * ca - vz * sa, vx * sa + vz * ca
	end
	local rox, roz = rotY(rootPos.X - axis.x, rootPos.Z - axis.z)
	local newRootX, newRootZ = axis.x + rox, axis.z + roz
	local localToGlobal, rootIdx = {}, nil
	for li, bp in ipairs(blueprint) do
		local relx, relz = rotY(bp.rel.X, bp.rel.Z)
		local pos = Vector3.new(newRootX + relx, rootPos.Y + bp.rel.Y, newRootZ + relz)
		local par = (bp.parentLocal == 0) and rootParent or localToGlobal[bp.parentLocal]
		local surf = (li == 1) and rootSurface or bp.surface
		local sid = (li == 1) and symId or nil
		local sidx = (li == 1) and symIndex or nil
		local idx = self:_appendPart(bp.id, CFrame.new(pos), par, surf, sid, sidx)
		localToGlobal[li] = idx
		if li == 1 then
			rootIdx = idx
		end
	end
	return rootIdx
end

-- Place a unit (single part or a picked-up subtree) at the snap, applying symmetry:
-- onto a symmetric target it mirrors to every sibling; otherwise it spreads `symCount`
-- copies around the core axis. Returns the primary (first) root index.
function VehicleController:PlaceUnit(blueprint, rootPos, parent, rootSurface, symCount)
	symCount = math.max(1, math.floor(symCount or 1))
	local axis = (parent and self:GetRootAxis(parent)) or { x = 0, z = 0 }
	local group = parent and self:GetSymGroup(parent) or nil

	local copies = {}
	if group and #group == symCount and symCount > 1 then
		-- Auto-match: one copy on each sibling, at the same relative position.
		local tIdx = self._parts[parent].symIndex or 0
		for _, sib in ipairs(group) do
			local da = ((sib.symIndex - tIdx) % symCount) * (2 * math.pi / symCount)
			copies[#copies + 1] = { parent = sib.index, angle = da }
		end
	else
		for k = 0, symCount - 1 do
			copies[#copies + 1] = { parent = parent, angle = k * (2 * math.pi / symCount) }
		end
	end

	local symId = (#copies > 1) and self:NewSymId() or nil
	local primary
	for ci, c in ipairs(copies) do
		local idx = self:_addUnitCopy(blueprint, rootPos, c.parent, rootSurface, axis, c.angle, symId, ci - 1)
		if ci == 1 then
			primary = idx
		end
	end
	self:_recompute()
	return primary
end

-- Move an existing part to a new CFrame (and optionally re-parent it).
function VehicleController:MovePart(index, cf, parent)
	local p = self._parts[index]
	if not p then
		return
	end
	p.cf = cf
	if parent ~= nil then
		p.parent = (parent ~= false) and parent or nil
	end
	self:_recompute()
end

-- Delete a part along with its whole subtree AND any symmetric copies (and their
-- subtrees) -- consistent with how picking a part up grabs them.
function VehicleController:RemovePart(index)
	if not self._parts[index] then
		return
	end
	local removeSet = {}
	for _, g in ipairs(self:GetSymGroup(index)) do
		for _, gi in ipairs(self:GetSubtree(g.index)) do
			removeSet[gi] = true
		end
	end
	self:RemoveParts(removeSet)
end

function VehicleController:Clear()
	self._parts = {}
	self:_recompute()
end

function VehicleController:GetParts()
	return self._parts
end

function VehicleController:GetStats()
	return self._stats
end

-- ---- Staging design (the staging panel) ----

function VehicleController:GetStageCount()
	return self._stageCount or 0
end

function VehicleController:GetCurrentStageIndex()
	return self._stageIndex or 1
end

-- Distinct fuel sections (with tankage) feeding a stage's engines -- so the staging
-- panel can draw one fuel gauge per booster/section in that stage.
function VehicleController:GetStageSections(stage)
	local secs, seen = {}, {}
	for i, p in ipairs(self._parts) do
		if isEngine(p.def) and p.stage == stage then
			local sec = self._sectionOf[i]
			if sec and not seen[sec] and (self._sectionCapacity[sec] or 0) > 0 then
				seen[sec] = true
				secs[#secs + 1] = sec
			end
		end
	end
	return secs
end

-- Remaining fuel fraction (0..1) of a fuel section, for its gauge.
function VehicleController:GetSectionFuelFrac(sec)
	local cap = self._sectionCapacity[sec] or 0
	if cap <= 0 then
		return 0
	end
	return math.clamp((self._sectionFuel[sec] or 0) / cap, 0, 1)
end

-- Kind tag for a part's staging chip / icon.
local function partKind(def)
	if isEngine(def) then
		return "engine"
	elseif def.parachute then
		return "chute"
	elseif def.radial then
		return "radialdecoupler"
	end
	return "decoupler"
end

-- For the staging panel: actuators grouped by stage, then by part id (symmetry copies
-- collapse into one chip carrying a count + every copy's index).
function VehicleController:GetStageContents()
	local out = {}
	for s = 1, (self._stageCount or 0) do
		out[s] = {}
	end
	for i, p in ipairs(self._parts) do
		if isActuator(p.def) and p.stage then
			local s = math.clamp(p.stage, 1, math.max(self._stageCount or 1, 1))
			out[s] = out[s] or {}
			local group
			for _, g in ipairs(out[s]) do
				if g.id == p.id then
					group = g
					break
				end
			end
			if group then
				group.count += 1
				group.indices[#group.indices + 1] = i
			else
				out[s][#out[s] + 1] =
					{ id = p.id, def = p.def, kind = partKind(p.def), count = 1, indices = { i } }
			end
		end
	end
	return out
end

function VehicleController:SetPartsStage(indices, stage)
	self._autoStage = false
	stage = math.max(1, math.floor(stage))
	for _, i in ipairs(indices) do
		local p = self._parts[i]
		if p and isActuator(p.def) then
			p.stage = stage
		end
	end
	self._stageFloor = math.max(self._stageFloor or 0, stage)
	self:_recompute()
end

function VehicleController:SetPartStage(index, stage)
	self:SetPartsStage({ index }, stage)
end

-- Swap two stages' fire order (▲▼ in the panel).
function VehicleController:SwapStages(a, b)
	if a == b then
		return
	end
	self._autoStage = false
	for _, p in ipairs(self._parts) do
		if isActuator(p.def) and p.stage then
			if p.stage == a then
				p.stage = b
			elseif p.stage == b then
				p.stage = a
			end
		end
	end
	self:_recompute()
end

function VehicleController:AddStage()
	self._autoStage = false
	self._stageFloor = math.max(self._stageFloor or 0, self:_maxStage()) + 1
	self:_recompute()
end

-- ---- Runtime (flight) ----

function VehicleController:ResetRuntime()
	self._stageIndex = 1
	self._sectionFuel = {}
	for root, cap in pairs(self._sectionCapacity or {}) do
		self._sectionFuel[root] = cap
	end
	self:_computeActive()
	self.Changed:Fire()
end

-- Recompute which parts are still attached. In the VAB the whole craft is shown; in
-- flight, a part is active iff it is still connected to the keep-root (command pod)
-- once every fired decoupler is cut out.
function VehicleController:_computeActive()
	self._runtimeVer += 1 -- active set changed: invalidate the per-frame caches
	local parts = self._parts
	local active = {}
	if self._editing then
		for i = 1, #parts do
			active[i] = true
		end
		self._active = active
		return
	end

	local fired = {}
	for i, p in ipairs(parts) do
		if isDecoupler(p.def) and p.stage and p.stage <= self._stageIndex then
			fired[i] = true
		end
	end

	local uf = {}
	for i = 1, #parts do
		uf[i] = i
	end
	local function find(x)
		while uf[x] ~= x do
			uf[x] = uf[uf[x]]
			x = uf[x]
		end
		return x
	end
	for i, p in ipairs(parts) do
		local pr = p.parent
		if pr and parts[pr] and not fired[i] and not fired[pr] then
			local ri, rp = find(i), find(pr)
			if ri ~= rp then
				uf[ri] = rp
			end
		end
	end

	local keep = self._keepRoot
	for i = 1, #parts do
		if fired[i] then
			active[i] = false
		elseif keep and find(i) == find(keep) then
			active[i] = true
		else
			active[i] = false
		end
	end
	self._active = active
end

function VehicleController:_isActive(i)
	return self._active and self._active[i] == true
end

-- Current fuel held by a tank: its share of its section's remaining fuel.
function VehicleController:_currentFuel(i)
	local def = self._parts[i].def
	local cap = def.fuel
	if not cap or cap <= 0 then
		return 0
	end
	local sec = self._sectionOf[i]
	if not sec then
		return 0
	end
	local secCap = self._sectionCapacity[sec] or 0
	if secCap <= 0 then
		return 0
	end
	return cap * ((self._sectionFuel[sec] or 0) / secCap)
end

-- Active (still-attached) part definitions, bottom -> top.
function VehicleController:GetActiveParts()
	local out = {}
	for _, i in ipairs(self._order) do
		if self:_isActive(i) then
			out[#out + 1] = self._parts[i].def
		end
	end
	return out
end

-- Active parts with stage, design index, and build CFrame, bottom -> top.
function VehicleController:GetActiveLayout()
	local out = {}
	for _, i in ipairs(self._order) do
		if self:_isActive(i) then
			local part = self._parts[i]
			out[#out + 1] = { def = part.def, stage = part.stage or 0, index = i, cf = part.cf }
		end
	end
	return out
end

-- Engines that are firing right now: active, ignited (stage already reached), with fuel.
-- Each carries its build-space lateral position so flight can build the thrust torque.
-- Cached per runtime version (called several times a frame).
function VehicleController:GetActiveEngines()
	if self._enginesCache and self._enginesVer == self._runtimeVer then
		return self._enginesCache
	end
	local out = self:_computeActiveEngines()
	self._enginesCache = out
	self._enginesVer = self._runtimeVer
	return out
end

function VehicleController:_computeActiveEngines()
	local out = {}
	if self._editing then
		return out
	end
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) and isEngine(p.def) and (p.stage or math.huge) <= self._stageIndex then
			local sec = self._sectionOf[i]
			local rem = sec and (self._sectionFuel[sec] or 0) or 0
			if rem > 1e-6 then
				out[#out + 1] = {
					x = p.cf.X,
					z = p.cf.Z,
					thrust = p.def.thrust or 0,
					ve = p.def.exhaustVelocity or 1,
					section = sec,
					index = i,
				}
			end
		end
	end
	return out
end

function VehicleController:GetCurrentMass(): number
	local m = 0
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) then
			m += (p.def.mass or 0) + self:_currentFuel(i)
		end
	end
	return m
end

-- Net thrust along the nose / current mass (off-axis cancellation handled by the torque).
function VehicleController:GetThrustAccel(throttle): number
	local t = 0
	for _, e in ipairs(self:GetActiveEngines()) do
		t += e.thrust
	end
	if t <= 0 then
		return 0
	end
	local m = self:GetCurrentMass()
	if m <= 0 then
		return 0
	end
	return t * throttle / m
end

function VehicleController:ConsumeFuel(dt, throttle)
	if throttle <= 0 then
		return
	end
	for _, e in ipairs(self:GetActiveEngines()) do
		local sec = e.section
		if sec then
			local flow = (e.thrust / math.max(e.ve, 1e-3)) * throttle * dt
			self._sectionFuel[sec] = math.max(0, (self._sectionFuel[sec] or 0) - flow)
		end
	end
	self._runtimeVer += 1 -- fuel (hence mass / thrust / CoM) changed: invalidate caches
end

function VehicleController:CanStage(): boolean
	return (self._stageIndex or 1) < (self._stageCount or 0)
end

-- Group dropped part indices into connected clumps (so two boosters that drop together
-- become two separate spent bodies, not one).
function VehicleController:_groupDropped(dropped)
	local inSet = {}
	for _, i in ipairs(dropped) do
		inSet[i] = true
	end
	local uf = {}
	for _, i in ipairs(dropped) do
		uf[i] = i
	end
	local function find(x)
		while uf[x] ~= x do
			uf[x] = uf[uf[x]]
			x = uf[x]
		end
		return x
	end
	for _, i in ipairs(dropped) do
		local pr = self._parts[i].parent
		if pr and inSet[pr] then
			local ri, rp = find(i), find(pr)
			if ri ~= rp then
				uf[ri] = rp
			end
		end
	end
	local groups, map = {}, {}
	for _, i in ipairs(dropped) do
		local r = find(i)
		if not map[r] then
			map[r] = {}
			groups[#groups + 1] = map[r]
		end
		map[r][#map[r] + 1] = i
	end
	return groups
end

-- Fire the next stage. Returns the HEIGHT the craft base rises by once the spent parts
-- drop (so the flight loop can shift the upper stage up and keep it in place).
function VehicleController:Stage(): number
	if not self:CanStage() then
		return 0
	end
	local before = {}
	for i = 1, #self._parts do
		before[i] = self:_isActive(i)
	end
	local oldBase = self:GetRotProfile().base or 0

	self._stageIndex += 1
	self:_computeActive()

	local dropped = {}
	for i = 1, #self._parts do
		if before[i] and not self:_isActive(i) then
			dropped[#dropped + 1] = i
			-- The fuel left in a dropped section leaves with the booster: empty its gauge.
			local sec = self._sectionOf[i]
			if sec then
				self._sectionFuel[sec] = 0
			end
		end
	end
	local groups = self:_groupDropped(dropped)

	local newBase = self:GetRotProfile().base or oldBase
	self.Staged:Fire(groups)
	self.Changed:Fire()
	return math.max(0, newBase - oldBase)
end

-- Fuel fraction of the sections currently feeding a firing engine (the active gauge).
function VehicleController:GetFuelFraction(): number
	local rem, cap = 0, 0
	local seen = {}
	for _, e in ipairs(self:GetActiveEngines()) do
		if e.section and not seen[e.section] then
			seen[e.section] = true
			rem += self._sectionFuel[e.section] or 0
			cap += self._sectionCapacity[e.section] or 0
		end
	end
	return (cap > 0) and (rem / cap) or 0
end

function VehicleController:GetCurrentStageDV(): number
	local engines = self:GetActiveEngines()
	if #engines == 0 then
		return 0
	end
	local rem, cap, thrust, veSum = 0, 0, 0, 0
	local seen = {}
	for _, e in ipairs(engines) do
		thrust += e.thrust
		veSum += e.thrust * e.ve
		if e.section and not seen[e.section] then
			seen[e.section] = true
			rem += self._sectionFuel[e.section] or 0
			cap += self._sectionCapacity[e.section] or 0
		end
	end
	local ve = (thrust > 0) and (veSum / thrust) or 0
	local m = self:GetCurrentMass()
	local mf = m - rem
	if ve <= 0 or m <= 0 or mf <= 0 then
		return 0
	end
	return ve * math.log(m / mf)
end

-- Along-axis length of the active stack (base -> top), used by camera + touchdown.
function VehicleController:GetHeight(): number
	return self:GetRotProfile().length
end

-- Summed aerodynamic drag area of the active parts (the body's own drag -- this is what
-- the aero-torque model uses, so a deployed chute can't flip the craft).
function VehicleController:GetDragArea(): number
	local a = 0
	for _, def in ipairs(self:GetActiveParts()) do
		a += def.drag or 0
	end
	return a
end

-- Extra drag from DEPLOYED parachutes (stage already fired). Added to the translational
-- drag only -- it slows the descent without contributing aero torque.
function VehicleController:GetChuteDragArea(): number
	local a = 0
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) and p.def.parachute and (p.stage or math.huge) <= self._stageIndex then
			a += p.def.chuteDrag or 0
		end
	end
	return a
end

-- True if the active craft carries landing legs (a more forgiving touchdown).
function VehicleController:HasLandingLegs(): boolean
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) and p.def.landingLeg then
			return true
		end
	end
	return false
end

-- True if a parachute has been staged (so the renderer can show its canopy in air).
function VehicleController:HasDeployedChute(): boolean
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) and p.def.parachute and (p.stage or math.huge) <= self._stageIndex then
			return true
		end
	end
	return false
end

-- Rotational profile of the active stack, measured along the body axis (+Y = nose),
-- from the CURRENT masses (dry + remaining section fuel), so the CoM shifts as fuel
-- burns and stages drop:
--   com/cop  = centre of mass / pressure, as HEIGHTS above the base
--   inertia  = pitch/yaw moment of inertia about the CoM
--   margin   = com - cop  (>0 = aerodynamically STABLE; CoP behind CoM)
--   length   = base -> top extent
--   base     = build-space Y of the lowest point (for GetFlightOffset / staging)
--   comX/comZ = build-space lateral CoM (the thrust axis + the thrust-torque pivot)
-- Cached per runtime version (called several times a frame by flight + the renderer).
function VehicleController:GetRotProfile()
	if self._profCache and self._profVer == self._runtimeVer then
		return self._profCache
	end
	local prof = self:_computeRotProfile()
	self._profCache = prof
	self._profVer = self._runtimeVer
	return prof
end

function VehicleController:_computeRotProfile()
	local items = {}
	local totalM, sumMY, sumMX, sumMZ = 0, 0, 0, 0
	local sumDrag, sumDragY = 0, 0
	local minB, maxT = math.huge, -math.huge
	for i, p in ipairs(self._parts) do
		if self:_isActive(i) then
			local def = p.def
			local cy = p.cf.Y
			local h = def.height or 0
			local m = (def.mass or 0) + self:_currentFuel(i)
			local drag = def.drag or 0
			items[#items + 1] = { y = cy, m = m }
			totalM += m
			sumMY += m * cy
			sumMX += m * p.cf.X
			sumMZ += m * p.cf.Z
			sumDrag += drag
			sumDragY += drag * cy
			minB = math.min(minB, cy - h * 0.5)
			maxT = math.max(maxT, cy + h * 0.5)
		end
	end

	if totalM <= 0 or minB == math.huge then
		return { com = 0, cop = 0, inertia = 1, margin = 0, length = 0, mass = 0, base = 0, comX = 0, comZ = 0 }
	end

	local base = minB
	local comY = sumMY / totalM
	local copY = (sumDrag > 0) and (sumDragY / sumDrag) or comY
	local inertia = 0
	for _, it in ipairs(items) do
		local d = it.y - comY
		inertia += it.m * d * d
	end
	inertia = math.max(inertia, math.max(totalM, 1) * 1.5) -- floor so single parts aren't twitchy

	return {
		com = comY - base,
		cop = copY - base,
		inertia = inertia,
		margin = comY - copY,
		length = maxT - base,
		mass = totalM,
		base = base,
		comX = sumMX / totalM,
		comZ = sumMZ / totalM,
	}
end

-- Build-local point that should map to the flight base (CoM on the thrust axis, lowest
-- point on the pad). The renderer pivots the model so this point sits at state.position.
function VehicleController:GetFlightOffset(): Vector3
	local prof = self:GetRotProfile()
	return Vector3.new(prof.comX or 0, prof.base or 0, prof.comZ or 0)
end

-- Centre of the parts' bounding box in build space (for framing the VAB camera).
function VehicleController:GetBuildCenter(): Vector3
	if #self._parts == 0 then
		return Vector3.zero
	end
	local mn = Vector3.new(math.huge, math.huge, math.huge)
	local mx = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(self._parts) do
		local pos = p.cf.Position
		mn = Vector3.new(math.min(mn.X, pos.X), math.min(mn.Y, pos.Y), math.min(mn.Z, pos.Z))
		mx = Vector3.new(math.max(mx.X, pos.X), math.max(mx.Y, pos.Y), math.max(mx.Z, pos.Z))
	end
	return (mn + mx) * 0.5
end

function VehicleController:GetTelemetry(throttle)
	local engines = self:GetActiveEngines()
	return {
		mass = self:GetCurrentMass(),
		thrustAccel = self:GetThrustAccel(throttle),
		fuelFrac = self:GetFuelFraction(),
		stageIndex = math.min(self._stageIndex, math.max(self._stageCount, 1)),
		stageCount = self._stageCount,
		stageDV = self:GetCurrentStageDV(),
		hasEngine = #engines > 0,
	}
end

return VehicleController
