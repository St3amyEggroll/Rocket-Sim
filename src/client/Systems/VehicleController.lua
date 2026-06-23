--[[
	VehicleController
	Owner of: the active craft design AND its flight-time runtime (current stage,
	remaining fuel). Single source of truth for "what the rocket is".

	KSP-style 3D assembly: the design is a SET OF PARTS placed in 3D build space, each
	with an id, its definition, a build-local CFrame, and the index of the part it is
	attached to (parent; nil for the root). Build space has +Y up (the nose direction)
	and its origin at the launch-pad point; parts may float freely.

	Flight still runs on the proven ALONG-AXIS model: every scalar the simulation needs
	(mass, centre of mass, centre of pressure, moment of inertia, length, staging) is
	measured up the +Y body axis from the parts' positions, and GetFlightOffset re-centres
	the assembly (base on the pad, CoM on the thrust axis) for the renderer. Radial X/Z
	offsets are carried for the renderer + a later full-radial-flight pass.

	The VAB edits the set (AddPartAt/MovePart/RemovePart/Clear); the flight loop reads
	thrust/mass and burns fuel. Fires Changed whenever the active parts change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Signal = require(Shared:WaitForChild("Signal"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))
local CraftStats = require(Shared:WaitForChild("CraftStats"))

local VehicleController = {}

function VehicleController:Init()
	self._surfaceGravity = Config.BODY.mu / (Config.BODY.radius * Config.BODY.radius)
	self.Changed = Signal.new()
	self.Staged = Signal.new() -- fires (droppedStageNumber) just before Changed on a stage

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
	self._fuelRemaining = 0
	self:_recompute()
end

-- Bottom of a part along the build axis (used to order the stack for staging).
function VehicleController:_partBottom(part)
	return part.cf.Y - (part.def.height or 0) * 0.5
end

function VehicleController:_recompute()
	-- Order the parts bottom -> top by build height; the serial staging model reads them
	-- in that order (stable: ties keep insertion order).
	local order = {}
	for i = 1, #self._parts do
		order[i] = i
	end
	table.sort(order, function(a, b)
		local ba, bb = self:_partBottom(self._parts[a]), self:_partBottom(self._parts[b])
		if ba == bb then
			return a < b
		end
		return ba < bb
	end)
	self._order = order

	local defs = {}
	for pos, i in ipairs(order) do
		defs[pos] = self._parts[i].def
	end
	self._stats = CraftStats.analyze(defs, self._surfaceGravity)

	-- Map stage (keyed by ordered position) back to each part's index.
	self._stageOf = {}
	for pos, i in ipairs(order) do
		self._stageOf[i] = self._stats.stageOfPart[pos] or 0
	end

	self:ResetRuntime()
end

-- ---- Design editing (VAB) ----

-- Place a part at a build-local CFrame, attached to `parent` (a part index or nil for
-- the root). Returns the new part's index.
function VehicleController:AddPartAt(id, cf, parent)
	local def = Catalog.get(id)
	if not def then
		return nil
	end
	table.insert(self._parts, { id = id, def = def, cf = cf, parent = parent })
	self:_recompute()
	return #self._parts
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

function VehicleController:RemovePart(index)
	if not self._parts[index] then
		return
	end
	table.remove(self._parts, index)
	-- Repair parent links: orphan the removed part's children, shift higher indices down.
	for _, p in ipairs(self._parts) do
		if p.parent == index then
			p.parent = nil
		elseif p.parent and p.parent > index then
			p.parent -= 1
		end
	end
	self:_recompute()
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

-- ---- Runtime (flight) ----

function VehicleController:ResetRuntime()
	self._stageIndex = 1
	self._fuelRemaining = (self._stats.stageCount >= 1) and self._stats.stages[1].fuel or 0
	self.Changed:Fire()
end

-- True if a part (by index) is still attached (not yet jettisoned).
function VehicleController:_isActive(i)
	local st = self._stageOf[i] or 0
	return st == 0 or st >= self._stageIndex
end

-- Active (not-yet-jettisoned) part definitions, bottom -> top.
function VehicleController:GetActiveParts()
	local out = {}
	for _, i in ipairs(self._order) do
		if self:_isActive(i) then
			out[#out + 1] = self._parts[i].def
		end
	end
	return out
end

-- Active parts with their stage number (0 = payload), design index, and build CFrame,
-- bottom -> top -- so the renderer can place each part in 3D and split off a stage.
function VehicleController:GetActiveLayout()
	local out = {}
	for _, i in ipairs(self._order) do
		if self:_isActive(i) then
			local part = self._parts[i]
			out[#out + 1] = { def = part.def, stage = self._stageOf[i] or 0, index = i, cf = part.cf }
		end
	end
	return out
end

function VehicleController:GetCurrentMass(): number
	local s = self._stats
	if self._stageIndex > s.stageCount then
		return s.payloadMass
	end
	local st = s.stages[self._stageIndex]
	return st.massAbove + st.dryMass + self._fuelRemaining
end

function VehicleController:GetCurrentThrust(throttle): number
	local s = self._stats
	if self._stageIndex > s.stageCount or self._fuelRemaining <= 0 then
		return 0
	end
	return s.stages[self._stageIndex].thrust * throttle
end

function VehicleController:GetThrustAccel(throttle): number
	local m = self:GetCurrentMass()
	if m <= 0 then
		return 0
	end
	return self:GetCurrentThrust(throttle) / m
end

function VehicleController:ConsumeFuel(dt, throttle)
	local s = self._stats
	if self._stageIndex > s.stageCount or throttle <= 0 or self._fuelRemaining <= 0 then
		return
	end
	local st = s.stages[self._stageIndex]
	local flow = st.thrust / st.ve
	self._fuelRemaining = math.max(0, self._fuelRemaining - flow * throttle * dt)
end

function VehicleController:CanStage(): boolean
	return self._stageIndex <= self._stats.stageCount
end

-- Fire the current stage. Returns the HEIGHT the craft base rises by once the spent
-- parts drop (so the flight loop can shift the upper stage up and keep it in place).
function VehicleController:Stage(): number
	local s = self._stats
	if self._stageIndex > s.stageCount then
		return 0
	end
	local dropped = self._stageIndex
	local oldBase = self:GetRotProfile().base or 0

	self._stageIndex += 1
	self._fuelRemaining = (self._stageIndex <= s.stageCount) and s.stages[self._stageIndex].fuel or 0

	local newBase = self:GetRotProfile().base or oldBase
	self.Staged:Fire(dropped) -- renderer splits off the spent stage (uses the live model)
	self.Changed:Fire() -- ...then everything rebuilds for the new active craft
	return math.max(0, newBase - oldBase)
end

function VehicleController:GetFuelFraction(): number
	local s = self._stats
	if self._stageIndex > s.stageCount then
		return 0
	end
	local full = s.stages[self._stageIndex].fuel
	return (full > 0) and (self._fuelRemaining / full) or 0
end

function VehicleController:GetCurrentStageDV(): number
	local s = self._stats
	if self._stageIndex > s.stageCount then
		return 0
	end
	local st = s.stages[self._stageIndex]
	local m = self:GetCurrentMass()
	local mf = m - self._fuelRemaining
	if m <= 0 or mf <= 0 then
		return 0
	end
	return st.ve * math.log(m / mf)
end

-- Along-axis length of the active stack (base -> top), used by camera + touchdown.
function VehicleController:GetHeight(): number
	return self:GetRotProfile().length
end

-- Summed aerodynamic drag area of the active parts (used by the atmosphere model).
function VehicleController:GetDragArea(): number
	local a = 0
	for _, def in ipairs(self:GetActiveParts()) do
		a += def.drag or 0
	end
	return a
end

-- Rotational profile of the active stack, measured along the body axis (+Y = nose):
--   com     = centre of mass, as a HEIGHT above the base
--   cop     = centre of pressure (drag-weighted), height above base
--   inertia = pitch/yaw moment of inertia about the CoM
--   margin  = com - cop  (>0 = aerodynamically STABLE; CoP behind CoM)
--   length  = base -> top extent
--   base    = build-space Y of the lowest point (for GetFlightOffset / staging)
--   comX/comZ = build-space lateral CoM (so the renderer can put the thrust axis on it)
-- Masses use the wet part masses (a fixed, representative distribution).
function VehicleController:GetRotProfile()
	local items = {}
	local totalM, sumMY, sumMX, sumMZ = 0, 0, 0, 0
	local sumDrag, sumDragY = 0, 0
	local minB, maxT = math.huge, -math.huge
	for _, e in ipairs(self:GetActiveLayout()) do
		local def = e.def
		local cy = e.cf.Y
		local h = def.height or 0
		local m = (def.mass or 0) + (def.fuel or 0)
		local drag = def.drag or 0
		items[#items + 1] = { y = cy, m = m }
		totalM += m
		sumMY += m * cy
		sumMX += m * e.cf.X
		sumMZ += m * e.cf.Z
		sumDrag += drag
		sumDragY += drag * cy
		minB = math.min(minB, cy - h * 0.5)
		maxT = math.max(maxT, cy + h * 0.5)
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
	return {
		mass = self:GetCurrentMass(),
		thrustAccel = self:GetThrustAccel(throttle),
		fuelFrac = self:GetFuelFraction(),
		stageIndex = math.min(self._stageIndex, self._stats.stageCount),
		stageCount = self._stats.stageCount,
		stageDV = self:GetCurrentStageDV(),
		hasEngine = self._stageIndex <= self._stats.stageCount,
	}
end

function VehicleController:Start() end

return VehicleController
