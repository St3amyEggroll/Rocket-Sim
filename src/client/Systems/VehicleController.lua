--[[
	VehicleController
	Owner of: the active craft design AND its flight-time runtime (current stage,
	remaining fuel). Single source of truth for "what the rocket is".

	The design is an array of part definitions, BOTTOM -> TOP. The VAB edits it
	(AddPart/RemovePart/Clear); the flight loop reads thrust/mass and burns fuel.
	Fires Changed whenever the active parts change (edit, stage, reset) so the
	renderer rebuilds and the VAB UI refreshes.
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

	self._design = {}
	for _, id in ipairs(Config.LAUNCH.defaultDesign) do
		local def = Catalog.get(id)
		if def then
			table.insert(self._design, def)
		end
	end

	self._stageIndex = 1
	self._fuelRemaining = 0
	self:_recompute()
end

function VehicleController:_recompute()
	self._stats = CraftStats.analyze(self._design, self._surfaceGravity)
	self:ResetRuntime()
end

-- ---- Design editing (VAB) ----

function VehicleController:AddPart(id)
	local def = Catalog.get(id)
	if def then
		table.insert(self._design, def) -- append = add on top of the stack
		self:_recompute()
	end
end

-- Insert a part at a stack position (1 = bottom). Used by drag-and-drop assembly.
function VehicleController:InsertPart(index, id)
	local def = Catalog.get(id)
	if not def then
		return
	end
	index = math.clamp(index, 1, #self._design + 1)
	table.insert(self._design, index, def)
	self:_recompute()
end

function VehicleController:RemovePart(index)
	if self._design[index] then
		table.remove(self._design, index)
		self:_recompute()
	end
end

function VehicleController:Clear()
	self._design = {}
	self:_recompute()
end

function VehicleController:GetDesign()
	return self._design
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

-- Active (not-yet-jettisoned) parts, bottom -> top.
function VehicleController:GetActiveParts()
	local out = {}
	local stageOf = self._stats.stageOfPart
	for i, def in ipairs(self._design) do
		local st = stageOf[i] or 0
		if st == 0 or st >= self._stageIndex then
			out[#out + 1] = def
		end
	end
	return out
end

-- Same as GetActiveParts but each entry carries its stage number (0 = payload),
-- so the renderer can tag parts and split off a whole stage when it is jettisoned.
function VehicleController:GetActiveLayout()
	local out = {}
	local stageOf = self._stats.stageOfPart
	for i, def in ipairs(self._design) do
		local st = stageOf[i] or 0
		if st == 0 or st >= self._stageIndex then
			out[#out + 1] = { def = def, stage = st }
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

-- Fire the current stage. Returns the total HEIGHT of the jettisoned parts (so the
-- flight loop can shift the craft up by that much, keeping the upper stage in place
-- while the spent stage drops away). Returns 0 if there was nothing to stage.
function VehicleController:Stage(): number
	local s = self._stats
	if self._stageIndex > s.stageCount then
		return 0
	end
	local dropped = self._stageIndex

	local droppedHeight = 0
	for i, def in ipairs(self._design) do
		if (s.stageOfPart[i] or 0) == dropped then
			droppedHeight += def.height or 0
		end
	end

	self._stageIndex += 1
	self._fuelRemaining = (self._stageIndex <= s.stageCount) and s.stages[self._stageIndex].fuel or 0
	self.Staged:Fire(dropped) -- renderer splits off the spent stage (uses the live model)
	self.Changed:Fire() -- ...then everything rebuilds for the new active craft
	return droppedHeight
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

function VehicleController:GetHeight(): number
	local h = 0
	for _, def in ipairs(self:GetActiveParts()) do
		h += def.height
	end
	return h
end

-- Summed aerodynamic drag area of the active parts (used by the atmosphere model).
function VehicleController:GetDragArea(): number
	local a = 0
	for _, def in ipairs(self:GetActiveParts()) do
		a += def.drag or 0
	end
	return a
end

-- Rotational profile of the active stack, measured along the body axis from the
-- base (+y = toward the nose). Used for rigid-body attitude + aero stability:
--   com     = centre of mass (y)
--   cop     = centre of pressure (drag-weighted y)
--   inertia = pitch/yaw moment of inertia about the CoM (sum m * (y-com)^2)
--   margin  = com - cop  (>0 = aerodynamically STABLE; CoP behind CoM)
-- Masses use the wet part masses (a fixed, representative distribution); the slow
-- CoM drift as fuel burns is not modelled yet.
function VehicleController:GetRotProfile()
	local y = 0
	local totalM, sumMY, sumDrag, sumDragY = 0, 0, 0, 0
	local items = {}
	for _, def in ipairs(self:GetActiveParts()) do
		local cy = y + (def.height or 0) * 0.5
		local m = (def.mass or 0) + (def.fuel or 0)
		local drag = def.drag or 0
		items[#items + 1] = { y = cy, m = m }
		totalM += m
		sumMY += m * cy
		sumDrag += drag
		sumDragY += drag * cy
		y += def.height or 0
	end

	local com = (totalM > 0) and (sumMY / totalM) or 0
	local cop = (sumDrag > 0) and (sumDragY / sumDrag) or com
	local inertia = 0
	for _, it in ipairs(items) do
		local d = it.y - com
		inertia += it.m * d * d
	end
	inertia = math.max(inertia, math.max(totalM, 1) * 1.5) -- floor so single parts aren't twitchy

	return {
		com = com,
		cop = cop,
		inertia = inertia,
		margin = com - cop,
		length = y,
		mass = totalM,
	}
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
