--[[
	VesselController
	Persistent in-orbit vessels: the craft you "Leave in Orbit" (with a docking port) are saved
	per slot and rendered on-rails on later flights, so you can rendezvous and dock with them.

	Each vessel is propagated on its conic (OrbitMechanics) around its body and drawn through the
	floating origin when you're in the same SOI and within range. A target panel shows the
	distance + relative speed to the selected vessel; when your docking port meets a vessel
	slowly enough the craft latches (refuels + a one-time "dock" science award).

	The vessel list is mirrored from the server's State push; "Leave in Orbit" (MenuController)
	writes one via GameRemotes.SaveVessel.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))
local PartPreview = require(Shared:WaitForChild("PartPreview"))

local VesselController = {}

local BG = Color3.fromRGB(18, 21, 28)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)
local CYAN = Color3.fromRGB(120, 210, 255)

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function frameFromUp(pos, up)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
	local fwd = up:Cross(ref)
	if fwd.Magnitude < 1e-3 then
		fwd = up:Cross(Vector3.xAxis)
	end
	return CFrame.lookAt(pos, pos + fwd.Unit, up)
end

local function fmt(n)
	local a = math.abs(n)
	if a >= 1e6 then
		return string.format("%.2fMm", n / 1e6)
	elseif a >= 1e3 then
		return string.format("%.2fkm", n / 1e3)
	end
	return string.format("%.0fm", n)
end

-- Rebuild a vessel's visual proxy from its lightweight design (base sits at the model origin,
-- +Y up). No FX -- just the part geometry, shared with the build palette.
local function buildVesselModel(design)
	local model = Instance.new("Model")
	model.Name = "Vessel"

	local baseY = math.huge
	for _, e in ipairs(design) do
		local def = Catalog.get(e.id)
		if def and not e.radial then
			baseY = math.min(baseY, e.y - (def.height or 0) * 0.5)
		end
	end
	if baseY == math.huge then
		baseY = 0
	end

	for _, e in ipairs(design) do
		local def = Catalog.get(e.id)
		if def then
			local pos = Vector3.new(e.x, e.y - baseY, e.z)
			local placeCF
			if e.radial then
				local out = Vector3.new(e.x, 0, e.z)
				out = (out.Magnitude > 1e-3) and out.Unit or Vector3.xAxis
				placeCF = CFrame.fromMatrix(pos, out, Vector3.yAxis)
			else
				placeCF = CFrame.new(pos)
			end
			local sub = Instance.new("Model")
			PartPreview.geometry(sub, def)
			for _, bp in ipairs(sub:GetChildren()) do
				if bp:IsA("BasePart") then
					bp.CFrame = placeCF * bp.CFrame
					bp.Anchored = true
					bp.CanCollide = false
					bp.CanQuery = false
					bp.CastShadow = false
					bp.Parent = model
				end
			end
			sub:Destroy()
		end
	end

	local root = Instance.new("Part")
	root.Name = "VRoot"
	root.Anchored = true
	root.Transparency = 1
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.CanCollide = false
	root.CanQuery = false
	root.CFrame = CFrame.new()
	root.Parent = model
	model.PrimaryPart = root
	return model
end

function VesselController:Init()
	self._vessels = {}
	self._targetIndex = 0
end

function VesselController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	self._vehicle = Registry:Get("VehicleController")
	self._mode = Registry:Get("GameModeController")
	local Flight = Registry:Get("FlightController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._reportEv = remotes:WaitForChild("ReportMilestone")
		self._stateEv = remotes:WaitForChild("State")
		self._stateEv.OnClientEvent:Connect(function(state)
			if type(state) == "table" then
				self:_rebuild(state.vessels or {})
			end
		end)
		self._stateEv:FireServer()
	end

	self._folder = Instance.new("Folder")
	self._folder.Name = "Vessels"
	self._folder.Parent = Workspace

	self:_buildHUD(Players.LocalPlayer:WaitForChild("PlayerGui"))

	self._mode.ModeChanged:Connect(function()
		self:_refreshHUDVis()
	end)
	Flight:GetUpdatedSignal():Connect(function(state, info)
		self:_render(state, info)
	end)
end

function VesselController:_bodyCenter(bodyId, info)
	if bodyId == "moon" then
		return info.moonCenter or Orbit.vec(0, 0, 0)
	elseif bodyId == "sun" then
		return info.sunCenter or Orbit.vec(0, 0, 0)
	end
	return Orbit.vec(0, 0, 0)
end

local function bodyMu(bodyId)
	if bodyId == "moon" then
		return Config.MOON.mu
	elseif bodyId == "sun" then
		return Config.SUN.mu
	end
	return Config.BODY.mu
end

function VesselController:_rebuild(list)
	for _, v in ipairs(self._vessels) do
		if v.model then
			v.model:Destroy()
		end
	end
	self._vessels = {}
	for _, data in ipairs(list) do
		if type(data) == "table" and data.pos and data.vel and data.design then
			local model = buildVesselModel(data.design)
			self._vessels[#self._vessels + 1] = {
				name = data.name or "Vessel",
				bodyId = data.bodyId or "planet",
				mu = bodyMu(data.bodyId or "planet"),
				state0 = { position = Orbit.vec(data.pos.x, data.pos.y, data.pos.z), velocity = Orbit.vec(data.vel.x, data.vel.y, data.vel.z) },
				model = model,
				docked = false,
			}
		end
	end
	if self._targetIndex > #self._vessels then
		self._targetIndex = #self._vessels
	end
	if self._targetIndex == 0 and #self._vessels > 0 then
		self._targetIndex = 1
	end
end

function VesselController:_render(state, info)
	if not info then
		return
	end
	local flying = info.mode == "Flight" and not info.mapMode and not info.isMenu
	self:_refreshHUDVis()

	local mt = info.missionTime or 0
	for _, v in ipairs(self._vessels) do
		local prop = Orbit.propagate(v.state0, v.mu, mt) -- epoch 0: the saved state is the flight-start state
		v.relPos = prop.position
		v.relVel = prop.velocity

		local sameBody = v.bodyId == info.bodyId
		local show = false
		if flying and sameBody then
			local dx = v.relPos.x - state.position.x
			local dy = v.relPos.y - state.position.y
			local dz = v.relPos.z - state.position.z
			v.dist = math.sqrt(dx * dx + dy * dy + dz * dz)
			show = v.dist <= Config.DOCKING.renderRange
		else
			v.dist = nil
		end

		if show then
			local center = self:_bodyCenter(v.bodyId, info)
			local abs = Orbit.vec(v.relPos.x + center.x, v.relPos.y + center.y, v.relPos.z + center.z)
			local renderPos = self._origin:ToRender(abs)
			local up = Vector3.new(v.relPos.x, v.relPos.y, v.relPos.z)
			if v.model.Parent ~= self._folder then
				v.model.Parent = self._folder
			end
			v.model:PivotTo(frameFromUp(renderPos, up))
		elseif v.model.Parent then
			v.model.Parent = nil
		end
	end

	self:_updateReadout(state, info)
	if flying then
		self:_checkDock(state, info)
	end
end

function VesselController:_checkDock(state, info)
	if not self._vehicle:HasDockingPort() then
		return
	end
	local portH = self._vehicle:GetDockPortHeight() or 0
	local nose = (info.pointDir and Vector3.new(info.pointDir.x or info.pointDir.X, info.pointDir.y or info.pointDir.Y, info.pointDir.z or info.pointDir.Z)) or Vector3.yAxis
	local portPos = Vector3.new(state.position.x, state.position.y, state.position.z) + nose * portH
	local vel = Vector3.new(state.velocity.x, state.velocity.y, state.velocity.z)
	local D = Config.DOCKING

	for _, v in ipairs(self._vessels) do
		if v.bodyId == info.bodyId and v.relPos then
			local vp = Vector3.new(v.relPos.x, v.relPos.y, v.relPos.z)
			local dist = (vp - portPos).Magnitude
			if dist > D.dockDist * 2.5 then
				v.docked = false -- moved away: armed to dock again
			end
			if not v.docked and dist <= D.dockDist then
				local rel = (vel - Vector3.new(v.relVel.x, v.relVel.y, v.relVel.z)).Magnitude
				if rel <= D.dockSpeed then
					v.docked = true
					self._vehicle:Refuel()
					if self._reportEv then
						self._reportEv:FireServer("dock")
					end
					self:_flash(("DOCKED with %s  -  refueled"):format(v.name))
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- HUD ----

function VesselController:_buildHUD(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TargetHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 61
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local panel = Instance.new("TextButton")
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 12)
	panel.Size = UDim2.fromOffset(240, 70)
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.AutoButtonColor = false
	panel.Text = ""
	corner(panel, 10)
	panel.Parent = gui
	panel.Activated:Connect(function()
		self:_cycleTarget()
	end)

	self._tName = Instance.new("TextLabel")
	self._tName.Position = UDim2.fromOffset(12, 8)
	self._tName.Size = UDim2.new(1, -24, 0, 18)
	self._tName.BackgroundTransparency = 1
	self._tName.Font = Enum.Font.GothamBold
	self._tName.TextSize = 13
	self._tName.TextXAlignment = Enum.TextXAlignment.Left
	self._tName.TextColor3 = CYAN
	self._tName.Text = "TARGET"
	self._tName.Parent = panel

	self._tInfo = Instance.new("TextLabel")
	self._tInfo.Position = UDim2.fromOffset(12, 28)
	self._tInfo.Size = UDim2.new(1, -24, 0, 20)
	self._tInfo.BackgroundTransparency = 1
	self._tInfo.Font = Enum.Font.Code
	self._tInfo.TextSize = 13
	self._tInfo.TextXAlignment = Enum.TextXAlignment.Left
	self._tInfo.TextColor3 = TEXT
	self._tInfo.Text = ""
	self._tInfo.Parent = panel

	self._tHint = Instance.new("TextLabel")
	self._tHint.Position = UDim2.fromOffset(12, 50)
	self._tHint.Size = UDim2.new(1, -24, 0, 14)
	self._tHint.BackgroundTransparency = 1
	self._tHint.Font = Enum.Font.Gotham
	self._tHint.TextSize = 11
	self._tHint.TextXAlignment = Enum.TextXAlignment.Left
	self._tHint.TextColor3 = DIM
	self._tHint.Text = "click to cycle target"
	self._tHint.Parent = panel
	self._flashToken = 0
end

function VesselController:_refreshHUDVis()
	if not self._gui then
		return
	end
	self._gui.Enabled = (self._mode:GetMode() == "Flight") and #self._vessels > 0
end

function VesselController:_cycleTarget()
	if #self._vessels == 0 then
		self._targetIndex = 0
		return
	end
	self._targetIndex = (self._targetIndex % #self._vessels) + 1
end

function VesselController:_updateReadout(state, info)
	if not self._gui or not self._gui.Enabled then
		return
	end
	local v = self._vessels[self._targetIndex]
	if not v then
		self._tName.Text = "NO TARGET"
		self._tInfo.Text = ""
		return
	end
	self._tName.Text = "» " .. v.name
	if v.bodyId ~= info.bodyId then
		self._tInfo.Text = "different orbit"
		self._tInfo.TextColor3 = DIM
		return
	end
	local dp = Vector3.new(v.relPos.x - state.position.x, v.relPos.y - state.position.y, v.relPos.z - state.position.z)
	local rel = Vector3.new(state.velocity.x - v.relVel.x, state.velocity.y - v.relVel.y, state.velocity.z - v.relVel.z)
	self._tInfo.Text = ("%s   %.1f m/s"):format(fmt(dp.Magnitude), rel.Magnitude)
	self._tInfo.TextColor3 = (dp.Magnitude <= Config.DOCKING.dockDist) and Color3.fromRGB(150, 235, 170) or TEXT
end

function VesselController:_flash(text)
	if not self._tHint then
		return
	end
	self._tHint.Text = text
	self._tHint.TextColor3 = Color3.fromRGB(150, 235, 170)
	self._flashToken += 1
	local token = self._flashToken
	task.delay(3, function()
		if self._flashToken == token and self._tHint then
			self._tHint.Text = "click to cycle target"
			self._tHint.TextColor3 = DIM
		end
	end)
end

return VesselController
