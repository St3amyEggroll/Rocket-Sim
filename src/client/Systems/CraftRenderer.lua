--[[
	CraftRenderer
	Owner of: the rendered rocket, the launch pad, lighting, and one-time world
	cleanup. The planet itself is real Roblox Terrain (see TerrainController), fixed
	at the world origin, so it needs no per-frame rendering here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))
local PartPreview = require(Shared:WaitForChild("PartPreview"))

local CraftRenderer = {}

local function makePart(parent, name, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local function addCylinder(model, name, height, radius, color, material, cf)
	return makePart(model, name, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		Color = color,
		-- A Roblox cylinder's length is its local X; rotate 90 deg about Z so the length
		-- runs along the part's local Y (the build axis), then place it at the part CFrame.
		CFrame = cf * CFrame.Angles(0, 0, math.rad(90)),
		Material = material,
	})
end

local function pointCFrame(posVec3, upVec3)
	local up = (upVec3.Magnitude > 1e-3) and upVec3.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(posVec3, posVec3 + fwd.Unit, up)
end

function CraftRenderer:Init() end

function CraftRenderer:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._vehicle = Registry:Get("VehicleController")
	local Flight = Registry:Get("FlightController")
	self._flight = Flight
	self._launchUp = Flight:GetLaunchUp() -- radial-out at the launch site (build +Y -> this)

	self:_cleanupWorld()
	self:_buildPad()
	self:_rebuildCraft()

	-- Staged fires BEFORE Changed, so split off the spent stage(s) from the live model
	-- first, then let Changed rebuild the (now smaller) active craft.
	self._vehicle.Staged:Connect(function(droppedGroups)
		self:_jettison(droppedGroups)
	end)
	self._vehicle.Changed:Connect(function()
		self:_rebuildCraft()
	end)
	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_render(state, info)
	end)
end

-- Split off jettisoned parts as free-falling spent stages that stay in the world. Each
-- GROUP (a connected clump of dropped part indices) becomes its own welded body, so a
-- pair of side boosters separates into two pieces, not one. Inline stages fall away
-- down the stack; radial boosters are flung outward from the core.
function CraftRenderer:_jettison(groups)
	local model = self._craft
	if not model or not groups then
		return
	end
	local craftCF = model:GetPivot()

	-- design index -> the rendered BaseParts that belong to it.
	local byIdx = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local idx = part:GetAttribute("idx")
			if idx then
				byIdx[idx] = byIdx[idx] or {}
				table.insert(byIdx[idx], part)
			end
		end
	end

	for _, group in ipairs(groups) do
		local parts, sum, n = {}, Vector3.zero, 0
		for _, idx in ipairs(group) do
			for _, part in ipairs(byIdx[idx] or {}) do
				parts[#parts + 1] = part
				sum += part.Position
				n += 1
			end
		end
		if #parts > 0 then
			local center = (n > 0) and (sum / n) or craftCF.Position
			local spent = Instance.new("Model")
			spent.Name = "SpentStage"
			local primary = parts[1]
			for _, part in ipairs(parts) do
				part.Parent = spent -- reparent keeps world position
				part.CanCollide = true
				part.CanQuery = true
				part.CastShadow = true
				if part ~= primary then
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = primary
					weld.Part1 = part
					weld.Parent = primary
				end
			end
			for _, part in ipairs(parts) do
				part.Anchored = false -- now physics debris (one welded body), gravity takes it
			end
			spent.PrimaryPart = primary
			spent.Parent = Workspace

			-- Outward = away from the craft axis (sideways for boosters); near-zero for an
			-- inline stage, so those just get a shove straight down the stack.
			local outward = center - craftCF.Position
			outward = outward - craftCF.UpVector * outward:Dot(craftCF.UpVector)
			local odir = (outward.Magnitude > 1e-3) and outward.Unit or -craftCF.UpVector
			primary.AssemblyLinearVelocity = (self._lastVel or Vector3.zero) + odir * 10 - craftCF.UpVector * 5
			primary.AssemblyAngularVelocity = odir:Cross(craftCF.UpVector) * 0.6
			Debris:AddItem(spent, 45)
		end
	end
end

function CraftRenderer:_cleanupWorld()
	for _, inst in ipairs(Lighting:GetChildren()) do
		if inst:IsA("Atmosphere") or inst:IsA("Sky") then
			inst:Destroy()
		end
	end
	local bp = Workspace:FindFirstChild("Baseplate")
	if bp then
		bp:Destroy()
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("SpawnLocation") then
			inst:Destroy()
		end
	end
end

function CraftRenderer:_buildPad()
	-- Fixed at the equatorial launch site, oriented radial-out, top flush with the terrain
	-- there (origin is fixed, so this never moves). CanCollide so it reads as solid ground.
	local up = self._launchUp
	local surf = Planet.radiusForUnit(up.X, up.Y, up.Z)
	makePart(Workspace, "LaunchPad", {
		Size = Vector3.new(120, 8, 120),
		Color = Color3.fromRGB(90, 92, 100),
		Material = Enum.Material.Metal,
		CFrame = pointCFrame(up * (surf - 4), up),
	})
end

function CraftRenderer:_buildFins(model, centerPos, radius, stage, index)
	local count, span, finH, thick = 4, 3.4, 4.2, 0.4
	for i = 1, count do
		local ang = (i - 1) * (2 * math.pi / count)
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local pos = dir * (radius + span * 0.5 - 0.6) + centerPos
		local blade = makePart(model, "Fin" .. i, {
			Shape = Enum.PartType.Block,
			-- X = radial span, Y = vertical, Z = thickness (tangential).
			Size = Vector3.new(span, finH, thick),
			Color = Color3.fromRGB(150, 80, 70),
			Material = Enum.Material.Metal,
			CFrame = CFrame.fromMatrix(pos, dir, Vector3.yAxis),
		})
		blade:SetAttribute("stg", stage)
		blade:SetAttribute("idx", index)
		blade.CanQuery = true
	end
end

function CraftRenderer:_rebuildCraft()
	if self._craft then
		self._craft:Destroy()
	end
	local layout = self._vehicle:GetActiveLayout()

	local model = Instance.new("Model")
	model.Name = "Craft"
	-- Root (the model pivot) sits at the build-space origin; parts are placed at their
	-- build-local CFrames. _render maps the assembly onto the pad (VAB) or the craft
	-- position with the base/CoM on the thrust axis (flight).
	local root = makePart(model, "Root", { Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1, CFrame = CFrame.new(0, 0, 0) })
	model.PrimaryPart = root

	local bottomRadius = 3
	local bottomY = math.huge
	-- Tag each part with its stage AND design index, and make it queryable so the VAB
	-- can raycast-select it in 3D.
	local function tag(part, stage, index)
		part:SetAttribute("stg", stage)
		part:SetAttribute("idx", index)
		part.CanQuery = true
		return part
	end
	for _, entry in ipairs(layout) do
		local def, stage, index, cf = entry.def, entry.stage, entry.index, entry.cf
		if def.shape == "fins" then
			self:_buildFins(model, cf.Position, def.radius, stage, index)
		else
			-- Build the part's art (shared with the palette/staging icons). Axial parts are
			-- just translated to their build position; radial parts (side mounts, legs) are
			-- oriented so their art points outward from the stack axis.
			local placeCF
			if def.radial then
				local out = Vector3.new(cf.X, 0, cf.Z)
				out = (out.Magnitude > 1e-3) and out.Unit or Vector3.xAxis
				placeCF = CFrame.fromMatrix(cf.Position, out, Vector3.yAxis)
			else
				placeCF = cf
			end
			local sub = Instance.new("Model")
			PartPreview.geometry(sub, def)
			for _, bp in ipairs(sub:GetChildren()) do
				if bp:IsA("BasePart") then
					bp.CFrame = placeCF * bp.CFrame
					tag(bp, stage, index)
					bp.Parent = model
				end
			end
			sub:Destroy()

			local b = cf.Y - (def.height or 0) * 0.5
			if b < bottomY and not def.radial then
				bottomY = b
				bottomRadius = def.radius
			end
		end
	end
	if bottomY == math.huge then
		bottomY = 0
	end

	-- Flame + reentry glow ride the thrust axis (lateral CoM) at the base.
	local off = self._vehicle:GetFlightOffset()
	local prof = self._vehicle:GetRotProfile()
	local axisX, axisZ = off.X, off.Z

	local flame = makePart(model, "Flame", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 1.5, 12, bottomRadius * 1.5),
		Color = Color3.fromRGB(255, 150, 45),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CFrame = CFrame.new(axisX, bottomY - 6, axisZ),
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 70)
	light.Range = 40
	light.Brightness = 5
	light.Enabled = false
	light.Parent = flame

	-- Exhaust plume + smoke particles, shot down the stack (the flame's local -Y). Rates
	-- are driven by throttle in _render.
	local exhaust = Instance.new("ParticleEmitter")
	exhaust.Texture = "rbxasset://textures/particles/fire_main.dds"
	exhaust.Color = ColorSequence.new(Color3.fromRGB(255, 230, 150), Color3.fromRGB(255, 120, 40))
	exhaust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, bottomRadius * 1.4),
		NumberSequenceKeypoint.new(1, bottomRadius * 0.3),
	})
	exhaust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	exhaust.Lifetime = NumberRange.new(0.18, 0.34)
	exhaust.Speed = NumberRange.new(55, 80)
	exhaust.SpreadAngle = Vector2.new(7, 7)
	exhaust.EmissionDirection = Enum.NormalId.Bottom
	exhaust.LightEmission = 0.9
	exhaust.Rate = 0
	exhaust.Parent = flame

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(180, 180, 185), Color3.fromRGB(110, 110, 115))
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, bottomRadius * 1.2),
		NumberSequenceKeypoint.new(1, bottomRadius * 4),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Lifetime = NumberRange.new(0.6, 1.2)
	smoke.Speed = NumberRange.new(12, 26)
	smoke.SpreadAngle = Vector2.new(16, 16)
	smoke.EmissionDirection = Enum.NormalId.Bottom
	smoke.Rate = 0
	smoke.Parent = flame
	self._exhaust = exhaust
	self._smoke = smoke

	-- Reentry plasma envelope: a neon shell wrapping the craft, hidden until the
	-- flight loop reports reentry heating (then it glows orange -> white-hot).
	local glowH = math.max(prof.length, 6)
	local glow = makePart(model, "Reentry", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 3.4, glowH * 1.25, bottomRadius * 3.4),
		Color = Color3.fromRGB(255, 140, 50),
		Material = Enum.Material.Neon,
		Transparency = 1,
		CFrame = CFrame.new(axisX, bottomY + glowH * 0.4, axisZ),
	})

	-- Parachute canopy: a broad translucent dome above the nose, hidden until the flight
	-- loop reports a deployed chute (in air).
	local topY = (prof.base or 0) + (prof.length or 0)
	local canopy = makePart(model, "Chute", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bottomRadius * 5.5, bottomRadius * 3.2, bottomRadius * 5.5),
		Color = Color3.fromRGB(228, 96, 76),
		Material = Enum.Material.SmoothPlastic,
		Transparency = 1,
		CFrame = CFrame.new(axisX, topY + bottomRadius * 1.6, axisZ),
	})

	model.Parent = Workspace
	self._craft = model
	self._flame = flame
	self._flameLight = light
	self._reentryGlow = glow
	self._chute = canopy
	self._exploded = false

	-- Build aids (VAB only): centre-of-mass / thrust / lift markers, so you can see why a
	-- design is stable or flips. The flight model treats aero drag as acting on the thrust
	-- axis, so CoM and CoL share that axis and only their HEIGHT differs: CoL below CoM
	-- (toward the base) is stable; CoL above CoM (toward the nose) weathervanes -> it flips.
	self._indicators = {}
	local function makeMarker(name, color, pos, hidden)
		local mk = makePart(model, name, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(4.5, 4.5, 4.5),
			Color = color,
			Material = Enum.Material.Neon,
			Transparency = 1, -- shown only in the VAB (toggled in _render)
			CFrame = CFrame.new(pos),
		})
		mk:SetAttribute("hidden", hidden or false)
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(42, 15)
		bb.AlwaysOnTop = true
		bb.Enabled = false
		bb.Adornee = mk
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 13
		lbl.TextStrokeTransparency = 0.3
		lbl.TextColor3 = color
		lbl.Text = name
		lbl.Parent = bb
		bb.Parent = mk
		self._indicators[#self._indicators + 1] = mk
		return mk
	end

	local comPos = Vector3.new(prof.comX or 0, (prof.base or 0) + (prof.com or 0), prof.comZ or 0)
	local colPos = Vector3.new(prof.comX or 0, (prof.base or 0) + (prof.cop or 0), prof.comZ or 0)
	makeMarker("CoM", Color3.fromRGB(255, 210, 40), comPos) -- yellow
	makeMarker("CoL", Color3.fromRGB(70, 150, 255), colPos) -- blue
	-- Centre of thrust: thrust-weighted engine position (hidden when there are no engines).
	local tSum, tx, ty, tz = 0, 0, 0, 0
	for _, e in ipairs(layout) do
		local th = e.def.thrust or 0
		if th > 0 then
			tSum += th
			tx, ty, tz = tx + th * e.cf.X, ty + th * e.cf.Y, tz + th * e.cf.Z
		end
	end
	local cotPos = (tSum > 0) and Vector3.new(tx / tSum, ty / tSum, tz / tSum) or comPos
	makeMarker("CoT", Color3.fromRGB(225, 80, 255), cotPos, tSum <= 0) -- magenta
end

-- Blow the craft apart on a crash: every part becomes physics debris flung by the
-- blast (this is dead wreckage, so Roblox physics here is safe), cleaned up after a
-- few seconds. Flight itself never touches the Roblox solver.
function CraftRenderer:_explode(at)
	local model = self._craft
	self._craft = nil

	if model then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				local n = part.Name
				if n == "Root" or n == "Flame" or n == "Reentry" then
					part:Destroy() -- non-structural helpers, not debris
				else
					part.Anchored = false
					part.CanCollide = true
					part.CanQuery = true
					part.CastShadow = true
				end
			end
		end
		model.Name = "Wreckage"
		Debris:AddItem(model, 6)
	end

	local ex = Instance.new("Explosion")
	ex.Position = at
	ex.BlastRadius = 34
	ex.BlastPressure = 600000 -- fling the debris apart
	ex.DestroyJointsOnExplode = false -- don't ragdoll the player's avatar
	ex.Parent = Workspace
end

function CraftRenderer:_render(state, info)
	-- Sim state is relative to the active body (patched conics); add the body's centre to
	-- get the Terra-centric position the world is rendered around.
	local bc = (info and info.bodyCenter) or Orbit.vec(0, 0, 0)
	local bv = (info and info.bodyVel) or Orbit.vec(0, 0, 0)
	local absPos = Orbit.vec(state.position.x + bc.x, state.position.y + bc.y, state.position.z + bc.z)
	local craftRender = self._origin:ToRender(absPos)
	local v = state.velocity
	self._lastVel = Vector3.new(v.x + bv.x, v.y + bv.y, v.z + bv.z) -- separation velocity for spent stages

	-- Map view draws a compressed orbit near the origin; hide the real (true-scale) craft.
	if info and info.mapMode then
		if self._craft and self._craft.Parent then
			self._craft.Parent = nil
		end
		return
	elseif self._craft and not self._craft.Parent then
		self._craft.Parent = Workspace
	end

	-- Crash = explosion: blow up once, then there's nothing left to render until relaunch.
	if info and info.status == "Crashed" then
		if not self._exploded then
			self._exploded = true
			self:_explode(craftRender)
		end
		return
	end
	if not self._craft then
		return
	end

	local pd = info and info.pointDir or Orbit.vec(0, 1, 0)
	local up = Vector3.new(pd.x or pd.X, pd.y or pd.Y, pd.z or pd.Z)
	if info and info.mode == "VAB" then
		-- VAB: parts at their raw build positions, with build +Y pointing radial-out so the
		-- craft stands upright on the (radial) launch pad.
		self._craft:PivotTo(pointCFrame(craftRender, self._launchUp))
	else
		-- Flight: map the assembly's base (CoM on the thrust axis) onto the craft position.
		local off = self._vehicle:GetFlightOffset()
		self._craft:PivotTo(pointCFrame(craftRender, up) * CFrame.new(-off))
	end

	-- Build-aid markers (CoM/CoT/CoL): only while editing in the VAB.
	if self._indicators then
		local inVAB = info and info.mode == "VAB"
		for _, mk in ipairs(self._indicators) do
			local show = inVAB and not mk:GetAttribute("hidden")
			mk.Transparency = show and 0.35 or 1
			local bb = mk:FindFirstChildOfClass("BillboardGui")
			if bb then
				bb.Enabled = show
			end
		end
	end

	local throttle = (info and info.throttle) or 0
	local burning = info and info.powered and throttle > 0
	if burning then
		self._flame.Transparency = 0.2
		self._flame.Size = Vector3.new(self._flame.Size.X, 8 + 26 * throttle, self._flame.Size.Z)
		self._flameLight.Enabled = true
		self._flameLight.Brightness = 4 + 4 * throttle
	else
		self._flame.Transparency = 1
		self._flameLight.Enabled = false
	end
	-- Exhaust + smoke scale with throttle; in air the smoke billows (launch dust).
	if self._exhaust then
		local thick = info and info.inAtmo
		self._exhaust.Rate = burning and (90 * throttle) or 0
		self._smoke.Rate = burning and ((thick and 60 or 22) * throttle) or 0
	end

	if self._chute then
		self._chute.Transparency = (info and info.chuteDeployed) and 0.3 or 1
	end

	local re = (info and info.reentry) or 0
	if re > 0 then
		self._reentryGlow.Transparency = 1 - 0.6 * re
		-- orange (cool) -> white-hot (hot)
		self._reentryGlow.Color = Color3.fromRGB(255, 140 + math.floor(90 * re), 50 + math.floor(150 * re))
	else
		self._reentryGlow.Transparency = 1
	end
end

return CraftRenderer
