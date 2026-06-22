--[[
	VABController
	Owner of: the Vehicle Assembly Building UI + the 3D in-world build interaction.

	KSP-style: the parts live in a UI panel (LEFT), but you GRAB a part and it becomes
	a real 3D ghost in the world that snaps onto the actual rocket's attach nodes;
	click to place it. The first part is the anchor and the rest stack onto it. Click
	a placed part to select it; its stats show on the RIGHT.

	UI is for choosing parts + data only; the building itself happens on the 3D rocket
	(rendered by CraftRenderer, framed by the VAB orbit camera in CameraController).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Registry = require(Shared:WaitForChild("Registry"))
local Catalog = require(Shared:WaitForChild("PartCatalog"))

local VABController = {}

local PANEL = Color3.fromRGB(20, 23, 31)
local ROW = Color3.fromRGB(30, 34, 44)
local ACCENT = Color3.fromRGB(120, 200, 255)
local TEXT = Color3.fromRGB(230, 234, 240)
local DIM = Color3.fromRGB(150, 158, 170)

local CATS = {
	{ id = "command", label = "Pods", color = Color3.fromRGB(90, 150, 230) },
	{ id = "fuel", label = "Fuel", color = Color3.fromRGB(200, 205, 215) },
	{ id = "engine", label = "Engines", color = Color3.fromRGB(222, 132, 70) },
	{ id = "structure", label = "Struct", color = Color3.fromRGB(132, 140, 152) },
}
local CAT_COLOR = {}
for _, c in ipairs(CATS) do
	CAT_COLOR[c.id] = c.color
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function panel(parent, pos, size, title)
	local f = Instance.new("Frame")
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = PANEL
	f.BackgroundTransparency = 0.08
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 10)
	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -24, 0, 22)
	header.Position = UDim2.fromOffset(14, 10)
	header.BackgroundTransparency = 1
	header.Font = Enum.Font.GothamBold
	header.TextSize = 14
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextColor3 = ACCENT
	header.Text = title
	header.Parent = f
	return f
end

function VABController:Init()
	self._partCards = {}
	self._tabBtns = {}
	self._activeCat = CATS[1].id
	self._selected = nil
	self._placing = nil
	self._snapIndex = nil
end

function VABController:Start()
	self._vehicle = Registry:Get("VehicleController")
	self._mode = Registry:Get("GameModeController")
	self._origin = Registry:Get("FloatingOriginController")
	self._flight = Registry:Get("FlightController")
	local player = Players.LocalPlayer

	self:_build(player:WaitForChild("PlayerGui"))
	self:_makeNodeIndicator()

	self._vehicle.Changed:Connect(function()
		self:_refresh()
	end)
	self._mode.ModeChanged:Connect(function(m)
		local vab = (m == "VAB")
		self._gui.Enabled = vab
		if not vab then
			self:_endPlacing()
		end
	end)
	self._gui.Enabled = (self._mode:GetMode() == "VAB")

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		self:_onInput(input, gameProcessed)
	end)
	RunService:BindToRenderStep("RocketSim_VAB", Enum.RenderPriority.Camera.Value + 1, function()
		if self._placing then
			self:_updateGhost()
		end
	end)

	self:_renderPalette()
	self:_refresh()
end

-- ---------------------------------------------------------------- UI ----

function VABController:_build(parentGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimVAB"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = parentGui
	self._gui = gui

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 12)
	title.Size = UDim2.fromOffset(560, 30)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = ACCENT
	title.Text = "VEHICLE ASSEMBLY BUILDING"
	title.Parent = gui

	self:_buildPalette(gui)
	self:_buildRight(gui)
	self:_buildControls(gui)
end

function VABController:_buildPalette(gui)
	local pane = panel(gui, UDim2.fromOffset(16, 56), UDim2.fromOffset(248, 470), "PARTS  (click to grab)")

	local tabs = Instance.new("Frame")
	tabs.Position = UDim2.fromOffset(12, 38)
	tabs.Size = UDim2.new(1, -24, 0, 30)
	tabs.BackgroundTransparency = 1
	tabs.Parent = pane
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.Padding = UDim.new(0, 4)
	tl.Parent = tabs

	for _, cat in ipairs(CATS) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.25, -3, 1, 0)
		b.BackgroundColor3 = ROW
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 12
		b.TextColor3 = DIM
		b.Text = cat.label
		b.Parent = tabs
		corner(b, 6)
		b.Activated:Connect(function()
			self._activeCat = cat.id
			self:_renderPalette()
		end)
		self._tabBtns[cat.id] = b
	end

	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = UDim2.fromOffset(12, 74)
	scroller.Size = UDim2.new(1, -24, 1, -86)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 5
	scroller.CanvasSize = UDim2.new()
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.Parent = pane
	local pl = Instance.new("UIListLayout")
	pl.Padding = UDim.new(0, 6)
	pl.Parent = scroller
	self._paletteList = scroller
end

function VABController:_renderPalette()
	for id, b in pairs(self._tabBtns) do
		local active = (id == self._activeCat)
		b.BackgroundColor3 = active and CAT_COLOR[id] or ROW
		b.TextColor3 = active and Color3.fromRGB(20, 22, 28) or DIM
	end
	for _, card in ipairs(self._partCards) do
		card:Destroy()
	end
	self._partCards = {}
	for _, id in ipairs(Catalog.order) do
		local def = Catalog.get(id)
		if def.category == self._activeCat then
			self:_addPartCard(def, id)
		end
	end
end

function VABController:_addPartCard(def, id)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 50)
	b.BackgroundColor3 = ROW
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Text = ""
	b.Parent = self._paletteList
	corner(b, 6)

	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(0, 5, 1, -10)
	stripe.Position = UDim2.fromOffset(6, 5)
	stripe.BackgroundColor3 = CAT_COLOR[def.category] or DIM
	stripe.BorderSizePixel = 0
	stripe.Parent = b
	corner(stripe, 3)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -24, 0, 20)
	name.Position = UDim2.fromOffset(18, 6)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = TEXT
	name.Text = def.name
	name.Parent = b

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -24, 0, 16)
	hint.Position = UDim2.fromOffset(18, 27)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = DIM
	hint.Text = "click, then place on rocket"
	hint.Parent = b

	b.Activated:Connect(function()
		self:_grab(id)
	end)
	table.insert(self._partCards, b)
end

function VABController:_buildRight(gui)
	local pane = panel(gui, UDim2.new(1, -330, 0, 56), UDim2.fromOffset(314, 470), "PART")

	self._partLabel = Instance.new("TextLabel")
	self._partLabel.Position = UDim2.fromOffset(14, 40)
	self._partLabel.Size = UDim2.new(1, -28, 0, 160)
	self._partLabel.BackgroundTransparency = 1
	self._partLabel.Font = Enum.Font.Code
	self._partLabel.TextSize = 14
	self._partLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._partLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._partLabel.TextColor3 = TEXT
	self._partLabel.Text = ""
	self._partLabel.Parent = pane

	self._removeBtn = Instance.new("TextButton")
	self._removeBtn.Position = UDim2.fromOffset(14, 206)
	self._removeBtn.Size = UDim2.new(1, -28, 0, 32)
	self._removeBtn.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	self._removeBtn.BorderSizePixel = 0
	self._removeBtn.Font = Enum.Font.GothamBold
	self._removeBtn.TextSize = 14
	self._removeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	self._removeBtn.Text = "Remove Part"
	self._removeBtn.Visible = false
	self._removeBtn.Parent = pane
	corner(self._removeBtn, 6)
	self._removeBtn.Activated:Connect(function()
		if self._selected then
			self._vehicle:RemovePart(self._selected)
			self._selected = nil
		end
	end)

	local craftTitle = Instance.new("TextLabel")
	craftTitle.Position = UDim2.fromOffset(14, 252)
	craftTitle.Size = UDim2.new(1, -28, 0, 18)
	craftTitle.BackgroundTransparency = 1
	craftTitle.Font = Enum.Font.GothamBold
	craftTitle.TextSize = 13
	craftTitle.TextXAlignment = Enum.TextXAlignment.Left
	craftTitle.TextColor3 = ACCENT
	craftTitle.Text = "CRAFT"
	craftTitle.Parent = pane

	self._craftLabel = Instance.new("TextLabel")
	self._craftLabel.Position = UDim2.fromOffset(14, 274)
	self._craftLabel.Size = UDim2.new(1, -28, 1, -286)
	self._craftLabel.BackgroundTransparency = 1
	self._craftLabel.Font = Enum.Font.Code
	self._craftLabel.TextSize = 14
	self._craftLabel.TextXAlignment = Enum.TextXAlignment.Left
	self._craftLabel.TextYAlignment = Enum.TextYAlignment.Top
	self._craftLabel.TextColor3 = TEXT
	self._craftLabel.Text = ""
	self._craftLabel.Parent = pane
end

function VABController:_buildControls(gui)
	local launch = Instance.new("TextButton")
	launch.AnchorPoint = Vector2.new(0.5, 1)
	launch.Position = UDim2.new(0.5, -90, 1, -16)
	launch.Size = UDim2.fromOffset(220, 50)
	launch.BackgroundColor3 = Color3.fromRGB(60, 170, 90)
	launch.BorderSizePixel = 0
	launch.Font = Enum.Font.GothamBold
	launch.TextSize = 20
	launch.TextColor3 = Color3.fromRGB(255, 255, 255)
	launch.Text = "LAUNCH"
	launch.Parent = gui
	corner(launch, 10)
	self._launchBtn = launch
	launch.Activated:Connect(function()
		self._mode:SetMode("Flight")
	end)

	local clear = Instance.new("TextButton")
	clear.AnchorPoint = Vector2.new(0.5, 1)
	clear.Position = UDim2.new(0.5, 100, 1, -16)
	clear.Size = UDim2.fromOffset(130, 50)
	clear.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	clear.BorderSizePixel = 0
	clear.Font = Enum.Font.GothamBold
	clear.TextSize = 16
	clear.TextColor3 = Color3.fromRGB(255, 255, 255)
	clear.Text = "CLEAR"
	clear.Parent = gui
	corner(clear, 10)
	clear.Activated:Connect(function()
		self._selected = nil
		self._vehicle:Clear()
	end)

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -72)
	hint.Size = UDim2.fromOffset(720, 20)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 13
	hint.TextColor3 = DIM
	hint.Text = "Click a part, move onto the rocket, click to place  •  click a part to inspect  •  Esc cancels  •  RMB orbit / wheel zoom"
	hint.Parent = gui
end

-- ------------------------------------------------------------- 3D build ----

function VABController:_makeNodeIndicator()
	local n = Instance.new("Part")
	n.Name = "VABNode"
	n.Shape = Enum.PartType.Ball
	n.Anchored = true
	n.CanCollide = false
	n.CanQuery = false
	n.CanTouch = false
	n.CastShadow = false
	n.Material = Enum.Material.Neon
	n.Color = ACCENT
	n.Size = Vector3.new(2, 2, 2)
	n.Transparency = 1
	n.Parent = Workspace
	self._node = n
end

function VABController:_buildBase()
	return self._origin:ToRender(self._flight:GetLaunchPosition())
end

function VABController:_grab(id)
	self:_endPlacing()
	local def = Catalog.get(id)
	if not def then
		return
	end
	local ghost = Instance.new("Part")
	ghost.Name = "VABGhost"
	ghost.Anchored = true
	ghost.CanCollide = false
	ghost.CanQuery = false
	ghost.CanTouch = false
	ghost.CastShadow = false
	ghost.Material = Enum.Material.ForceField
	ghost.Color = def.color
	ghost.Transparency = 0.35
	local gh
	if def.shape == "pod" then
		ghost.Shape = Enum.PartType.Ball
		ghost.Size = Vector3.new(def.radius * 1.9, def.radius * 1.5, def.radius * 1.9)
		gh = def.radius * 1.5
	else
		ghost.Shape = Enum.PartType.Cylinder
		gh = math.max(def.height or 0, 1.6)
		ghost.Size = Vector3.new(gh, def.radius * 2, def.radius * 2)
	end
	ghost.Parent = Workspace
	self._placing = { id = id, def = def, ghost = ghost, gh = gh, pod = (def.shape == "pod") }
	self._snapIndex = nil
end

function VABController:_endPlacing()
	if self._placing then
		self._placing.ghost:Destroy()
		self._placing = nil
	end
	self._snapIndex = nil
	if self._node then
		self._node.Transparency = 1
	end
end

-- Where along the build axis (height above the base) the mouse points, via a vertical
-- plane through the rocket facing the camera.
function VABController:_mouseHeight(base)
	local cam = Workspace.CurrentCamera
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local toCam = cam.CFrame.Position - base
	local n = Vector3.new(toCam.X, 0, toCam.Z)
	n = (n.Magnitude > 1e-3) and n.Unit or Vector3.zAxis
	local denom = ray.Direction:Dot(n)
	if math.abs(denom) < 1e-4 then
		return 0
	end
	local t = (base - ray.Origin):Dot(n) / denom
	local pt = ray.Origin + ray.Direction * t
	return pt.Y - base.Y
end

function VABController:_updateGhost()
	local base = self:_buildBase()
	local design = self._vehicle:GetDesign()
	local n = #design

	-- Cumulative node heights (0 = bottom, n = top).
	local cum = { [0] = 0 }
	for i = 1, n do
		cum[i] = cum[i - 1] + (design[i].height or 0)
	end

	local h = self:_mouseHeight(base)
	local total = cum[n]
	h = math.clamp(h, 0, total)

	-- Snap to nearest node.
	local bestK, bestD = 0, math.huge
	for k = 0, n do
		local d = math.abs(h - cum[k])
		if d < bestD then
			bestD = d
			bestK = k
		end
	end
	self._snapIndex = bestK + 1

	local p = self._placing
	local cy = cum[bestK] + p.gh * 0.5
	local pos = base + Vector3.new(0, cy, 0)
	if p.pod then
		p.ghost.CFrame = CFrame.new(pos)
	else
		p.ghost.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	end

	self._node.CFrame = CFrame.new(base + Vector3.new(0, cum[bestK], 0))
	self._node.Transparency = 0.2
end

function VABController:_place()
	local p = self._placing
	if not p then
		return
	end
	local idx = self._snapIndex or (#self._vehicle:GetDesign() + 1)
	self:_endPlacing()
	self._selected = idx
	self._vehicle:InsertPart(idx, p.id)
end

function VABController:_trySelect()
	local cam = Workspace.CurrentCamera
	local craft = Workspace:FindFirstChild("Craft")
	if not cam or not craft then
		return
	end
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { craft }
	local result = Workspace:Raycast(ray.Origin, ray.Direction * 8000, params)
	if result and result.Instance then
		local idx = result.Instance:GetAttribute("idx")
		if idx then
			self._selected = idx
			self:_updatePartPanel()
		end
	end
end

function VABController:_onInput(input, gameProcessed)
	if self._mode:GetMode() ~= "VAB" then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if gameProcessed then
			return -- click landed on the UI
		end
		if self._placing then
			self:_place()
		else
			self:_trySelect()
		end
	elseif input.KeyCode == Enum.KeyCode.Escape then
		self:_endPlacing()
	end
end

-- ------------------------------------------------------------- panels ----

function VABController:_refresh()
	local design = self._vehicle:GetDesign()
	if self._selected and not design[self._selected] then
		self._selected = nil
	end
	self:_updatePartPanel()

	local stats = self._vehicle:GetStats()
	local prof = self._vehicle:GetRotProfile()
	local lines = {}
	lines[#lines + 1] = string.format("dV total   %.0f", stats.totalDeltaV)
	lines[#lines + 1] = string.format("Mass       %.2f t", stats.totalMass)
	lines[#lines + 1] = string.format("Launch TWR %.2f", stats.launchTWR)
	lines[#lines + 1] = string.format("Stages     %d", stats.stageCount)
	if prof.mass > 0 then
		lines[#lines + 1] = "Stability  " .. (prof.margin > 0 and "STABLE" or "UNSTABLE")
	end
	if stats.stageCount == 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "! Add an engine to launch."
	end
	self._craftLabel.Text = table.concat(lines, "\n")

	local ready = stats.stageCount > 0
	self._launchBtn.BackgroundColor3 = ready and Color3.fromRGB(60, 170, 90) or Color3.fromRGB(60, 70, 64)
	self._launchBtn.Text = ready and "LAUNCH" or "ADD AN ENGINE"
	self._launchBtn.Active = ready
	self._launchBtn.AutoButtonColor = ready
end

function VABController:_updatePartPanel()
	local design = self._vehicle:GetDesign()
	local def = self._selected and design[self._selected]
	if not def then
		self._partLabel.Text = "Click a part on the rocket\nto inspect it."
		self._partLabel.TextColor3 = DIM
		self._removeBtn.Visible = false
		return
	end
	self._partLabel.TextColor3 = TEXT
	self._removeBtn.Visible = true
	local lines = {}
	lines[#lines + 1] = def.name
	lines[#lines + 1] = "category  " .. def.category
	lines[#lines + 1] = string.format("mass      %.2f t", def.mass or 0)
	lines[#lines + 1] = string.format("size      %.1f x %.1f", (def.radius or 0) * 2, def.height or 0)
	lines[#lines + 1] = string.format("drag      %.2f", def.drag or 0)
	if def.fuel then
		lines[#lines + 1] = string.format("fuel      %.1f", def.fuel)
	end
	if def.category == "engine" then
		lines[#lines + 1] = string.format("thrust    %d", def.thrust or 0)
		lines[#lines + 1] = string.format("exhaust v %d", def.exhaustVelocity or 0)
	end
	self._partLabel.Text = table.concat(lines, "\n")
end

return VABController
