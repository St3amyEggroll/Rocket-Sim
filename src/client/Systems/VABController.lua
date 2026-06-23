--[[
	VABController
	Owner of: the Vehicle Assembly Building UI + the 3D, KSP-style build interaction.

	Building is real 3D, drag-and-drop:
	  * Press-and-hold a part in the LEFT palette -> it becomes a 3D ghost on your cursor.
	  * Move it in the world; near a part's top/bottom it STACK-snaps, near a side it
	    SURFACE-snaps (radial). Away from the rocket it just floats on a build plane.
	  * Release to drop it -- snapped onto the rocket, or free-floating off it (the first
	    part you drop is the anchor; drop it anywhere in 3D).
	  * Press-and-hold an already-placed part to pick it back up and move it.
	  * Release over the parts list to delete the held part. Esc cancels a move.

	The UI is only for choosing parts + showing stats; assembly happens on the 3D rocket
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
	self._selected = nil -- part index of the last placed/inspected part
	self._drag = nil -- { id, def, ghost, pod, originalCF, originalParent }
	self._snap = nil -- { cf, parent, isSurface } the ghost will commit to on release
	self._snapMode = true -- node/angle snapping on (vs free placement)
	self._symmetry = 1 -- 1..8 radial copies for surface-attached parts
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
			self:_cancelDrag(false)
		end
	end)
	self._gui.Enabled = (self._mode:GetMode() == "VAB")

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		self:_onInputBegan(input, gameProcessed)
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and self._drag then
			self:_onRelease()
		end
	end)
	RunService:BindToRenderStep("RocketSim_VAB", Enum.RenderPriority.Camera.Value + 1, function()
		if self._drag then
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
	self:_buildTools(gui)
end

-- Snap-mode + symmetry toggles (top centre, under the title).
function VABController:_buildTools(gui)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 46)
	frame.Size = UDim2.fromOffset(320, 32)
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = frame

	local function toolBtn(w)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(w, 30)
		b.BackgroundColor3 = ROW
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.TextColor3 = TEXT
		b.AutoButtonColor = true
		b.Parent = frame
		corner(b, 6)
		return b
	end

	self._snapBtn = toolBtn(152)
	self._snapBtn.Activated:Connect(function()
		self:_toggleSnap()
	end)
	self._symBtn = toolBtn(152)
	self._symBtn.Activated:Connect(function()
		self:_cycleSymmetry(1)
	end)
	self:_updateToolBtns()
end

function VABController:_toggleSnap()
	self._snapMode = not self._snapMode
	self:_updateToolBtns()
end

function VABController:_cycleSymmetry(delta)
	self._symmetry = ((self._symmetry - 1 + delta) % 8) + 1
	self:_updateToolBtns()
end

function VABController:_updateToolBtns()
	if self._snapBtn then
		self._snapBtn.Text = "Snap [C]: " .. (self._snapMode and "ON" or "OFF (free)")
		self._snapBtn.BackgroundColor3 = self._snapMode and Color3.fromRGB(50, 110, 70) or ROW
	end
	if self._symBtn then
		self._symBtn.Text = "Symmetry [X]: " .. self._symmetry .. "x"
		self._symBtn.BackgroundColor3 = (self._symmetry > 1) and Color3.fromRGB(60, 90, 130) or ROW
	end
end

function VABController:_buildPalette(gui)
	local pane = panel(gui, UDim2.fromOffset(16, 56), UDim2.fromOffset(248, 470), "PARTS  (hold + drag)")
	self._palettePane = pane

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
	hint.Text = "hold + drag into the world"
	hint.Parent = b

	-- Press (not click) begins dragging a new part; release in the world drops it.
	b.MouseButton1Down:Connect(function()
		self:_beginDragNew(id)
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
	hint.Size = UDim2.fromOffset(900, 20)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Code
	hint.TextSize = 13
	hint.TextColor3 = DIM
	hint.Text = "Hold + drag a part -- top/bottom STACK-snaps; over a body's side it SURFACE-snaps (slide up/down), else it rides the cursor  •  mount onto a radial decoupler's side to build a booster  •  set the firing order in STAGING (right)  •  C snap  •  X symmetry  •  Alt force-snap  •  drop on the list to delete  •  Esc cancels  •  RMB orbit"
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
	n.Size = Vector3.new(2.4, 2.4, 2.4)
	n.Transparency = 1
	n.Parent = Workspace
	self._node = n
end

-- Build space: origin at the launch-pad point, +Y up. The VAB renders the craft at this
-- origin (CraftRenderer), so build-local CFrames map to the world by a pure translation.
function VABController:_buildOrigin()
	return self._origin:ToRender(self._flight:GetLaunchPosition())
end
function VABController:_buildToWorld(cf)
	return CFrame.new(self:_buildOrigin()) * cf
end
function VABController:_worldToBuild(worldCF)
	return CFrame.new(self:_buildOrigin()):Inverse() * worldCF
end

function VABController:_makeGhost(def)
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
	if def.shape == "pod" then
		ghost.Shape = Enum.PartType.Ball
		ghost.Size = Vector3.new(def.radius * 1.9, def.radius * 1.5, def.radius * 1.9)
	else
		ghost.Shape = Enum.PartType.Cylinder
		local gh = math.max(def.height or 0, 1.2)
		ghost.Size = Vector3.new(gh, def.radius * 2, def.radius * 2)
	end
	ghost.Parent = Workspace
	return ghost
end

function VABController:_beginDragNew(id)
	local def = Catalog.get(id)
	if not def then
		return
	end
	self:_cancelDrag(false)
	self._drag = { id = id, def = def, ghost = self:_makeGhost(def), pod = (def.shape == "pod") }
	self._selected = nil
	self:_updatePartPanel()
end

function VABController:_beginDragExisting(index)
	local part = self._vehicle:GetParts()[index]
	if not part then
		return
	end
	self:_cancelDrag(false)
	self._drag = {
		id = part.id,
		def = part.def,
		ghost = self:_makeGhost(part.def),
		pod = (part.def.shape == "pod"),
		originalCF = part.cf,
		originalParent = part.parent,
		originalSurface = part.surface,
	}
	self._selected = nil
	self._vehicle:RemovePart(index) -- lift it off; rebuilds the live model without it
	self:_updatePartPanel()
end

-- Cancel the active drag. restore = re-add the picked-up part where it was.
function VABController:_cancelDrag(restore)
	local d = self._drag
	if not d then
		return
	end
	if d.ghost then
		d.ghost:Destroy()
	end
	self._drag = nil
	self._snap = nil
	if self._node then
		self._node.Transparency = 1
	end
	if restore and d.originalCF then
		self._selected = self._vehicle:AddPartAt(d.id, d.originalCF, d.originalParent, d.originalSurface)
	end
	self:_updatePartPanel()
end

-- Release: drop the held part. Over the parts list -> discard/delete; otherwise commit
-- it at the current snap (on the rocket) or free-floating position.
function VABController:_onRelease()
	local d = self._drag
	if not d then
		return
	end
	if self:_cursorOverPalette() then
		self:_cancelDrag(false) -- dropped on the list: discard (deletes a picked-up part)
		return
	end
	local snap = self._snap
	local cf = snap and snap.cf or self:_freePlane()
	local parent = snap and snap.parent or nil
	local isSurface = snap and snap.isSurface
	d.ghost:Destroy()
	self._drag = nil
	self._snap = nil
	if self._node then
		self._node.Transparency = 1
	end
	-- Symmetry: a surface-attached part places N evenly-spaced copies around the parent's
	-- axis; everything else places a single part.
	if isSurface and parent and self._symmetry > 1 then
		self._selected = self:_placeSymmetry(d.id, cf, parent, self._symmetry)
	else
		self._selected = self._vehicle:AddPartAt(d.id, cf, parent, isSurface)
	end
	self:_updatePartPanel()
end

function VABController:_placeSymmetry(id, cf, parent, n)
	local parentPart = self._vehicle:GetParts()[parent]
	if not parentPart then
		return self._vehicle:AddPartAt(id, cf, parent, true)
	end
	local px, pz = parentPart.cf.X, parentPart.cf.Z
	local ox, oz = cf.X - px, cf.Z - pz
	local y = cf.Y
	local last
	for k = 0, n - 1 do
		local a = k * (2 * math.pi / n)
		local ca, sa = math.cos(a), math.sin(a)
		last = self._vehicle:AddPartAt(id, CFrame.new(px + ox * ca - oz * sa, y, pz + ox * sa + oz * ca), parent, true)
	end
	return last
end

function VABController:_cursorOverPalette()
	local pane = self._palettePane
	if not pane then
		return false
	end
	local m = UserInputService:GetMouseLocation()
	local p, s = pane.AbsolutePosition, pane.AbsoluteSize
	return m.X >= p.X and m.X <= p.X + s.X and m.Y >= p.Y and m.Y <= p.Y + s.Y
end

-- Free placement on a camera-facing plane through the build origin (so you can drop a
-- part anywhere on screen in 3D, off the rocket).
function VABController:_freePlane()
	local cam = Workspace.CurrentCamera
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local O = self:_buildOrigin()
	local nrm = cam.CFrame.LookVector
	local denom = ray.Direction:Dot(nrm)
	local t = (math.abs(denom) > 1e-4) and ((O - ray.Origin):Dot(nrm) / denom) or (O - ray.Origin).Magnitude
	local pt = ray.Origin + ray.Direction * t
	return self:_worldToBuild(CFrame.new(pt))
end

-- Cursor's 3D point on a camera-facing plane through `planePoint` (world).
function VABController:_planePoint(ray, planePoint)
	local cam = Workspace.CurrentCamera
	local nrm = cam.CFrame.LookVector
	local denom = ray.Direction:Dot(nrm)
	local t = (math.abs(denom) > 1e-4) and ((planePoint - ray.Origin):Dot(nrm) / denom) or (planePoint - ray.Origin).Magnitude
	return ray.Origin + ray.Direction * t
end

-- Snap a horizontal direction to the nearest 15 degrees (angle snap, in snap mode).
function VABController:_snapAngleDir(dir)
	local ang = math.atan2(dir.Z, dir.X)
	local step = math.rad(15)
	ang = math.floor(ang / step + 0.5) * step
	return Vector3.new(math.cos(ang), 0, math.sin(ang))
end

-- Nearest stack node (a part's top/bottom cap) to `desired`. Returns
-- (centerWorld, parentIdx, nodeWorld, dist) or nil. Build space has +Y up and no
-- rotation, so world = build origin + part offset.
function VABController:_bestStack(desired, def, radius)
	local O = self:_buildOrigin()
	local gh = math.max(def.height or 0, 1.2)
	local best, center, parent, node = radius, nil, nil, nil
	for i, part in ipairs(self._vehicle:GetParts()) do
		local th = part.def.height or 0
		-- A body's top/bottom nodes are stack targets. Radial parts (fins, radial
		-- decouplers) are NOT stack targets -- things mount on their SIDE, not their ends.
		if th > 0 and not part.def.radial then
			local wp = O + part.cf.Position
			local top = wp + Vector3.new(0, th * 0.5, 0)
			local bot = wp - Vector3.new(0, th * 0.5, 0)
			local dt = (desired - top).Magnitude
			if dt < best then
				best, center, parent, node = dt, top + Vector3.new(0, gh * 0.5, 0), i, top
			end
			local db = (desired - bot).Magnitude
			if db < best then
				best, center, parent, node = db, bot - Vector3.new(0, gh * 0.5, 0), i, bot
			end
		end
	end
	if center then
		return center, parent, node, best
	end
	return nil
end

-- Nearest body side to `desired` (surface/radial attach). The SIDE (angle + radial
-- distance) snaps to the body, and you slide freely up/down it -- but ONLY while the
-- cursor is actually over that body's side. Off every part nothing snaps, so the held
-- part just rides the cursor. Targets include radial decouplers (mount a booster on the
-- decoupler's side). Returns (centerWorld, parentIdx, surfaceWorld, dist) or nil.
function VABController:_bestSurface(desired, def, radius)
	local O = self:_buildOrigin()
	local gr = def.radius or 1
	local SIDE_MARGIN = 1.5 -- a little reach past a body's ends still counts as "over it"
	local bestScore, bestSurf = math.huge, radius
	local center, parent, node = nil, nil, nil
	for i, part in ipairs(self._vehicle:GetParts()) do
		local pdef = part.def
		local th = pdef.height or 0
		-- Anything with a body height can take a side mount: tanks, pods, AND radial
		-- decouplers. Fins (height 0) are excluded.
		if th > 0 and pdef.surfaceTarget ~= false then
			local wp = O + part.cf.Position
			local pr = pdef.radius or 3
			local radial = Vector3.new(desired.X - wp.X, 0, desired.Z - wp.Z)
			local rdist = radial.Magnitude
			local surfDist = math.abs(rdist - pr) -- radial closeness to the side
			local outsideY = math.abs(desired.Y - wp.Y) - th * 0.5 -- >0 = past an end
			-- Snap only while over this body's side: close radially AND within its height.
			if surfDist < radius and outsideY <= SIDE_MARGIN then
				local score = surfDist + math.max(0, outsideY)
				if score < bestScore then
					local rdir = (rdist > 1e-3) and radial.Unit or Vector3.new(1, 0, 0)
					if self._snapMode then
						rdir = self:_snapAngleDir(rdir)
					end
					bestScore = score
					bestSurf = surfDist
					-- Slide freely along the body, clamped to its height (the attach point
					-- stays on the part, not floating in the reach margin).
					local clampedY = math.clamp(desired.Y, wp.Y - th * 0.5, wp.Y + th * 0.5)
					local axisPt = Vector3.new(wp.X, clampedY, wp.Z)
					center = axisPt + rdir * (pr + gr)
					parent = i
					node = axisPt + rdir * pr
				end
			end
		end
	end
	if center then
		return center, parent, node, bestSurf
	end
	return nil
end

-- Where the ghost should sit. In snap mode, find the nearest stack node AND the nearest
-- body side and take whichever is closer (KSP "guesses" which you mean by proximity);
-- in free mode, follow the cursor on a build plane. Returns
-- (buildCF, parentIdx|nil, nodeWorldPos|nil, isSurface).
function VABController:_snapTarget()
	local cam = Workspace.CurrentCamera
	local d = self._drag
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local O = self:_buildOrigin()
	local desired = self:_planePoint(ray, O + self._vehicle:GetBuildCenter())

	if not self._snapMode then
		return self:_worldToBuild(CFrame.new(desired)), nil, nil, false
	end

	-- Holding Alt widens the snap range (force-snap).
	local force = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
	local radius = force and 80 or 22

	local sCenter, sParent, sNode, sDist
	if not d.def.radial then
		sCenter, sParent, sNode, sDist = self:_bestStack(desired, d.def, radius)
	end
	local fCenter, fParent, fNode, fDist = self:_bestSurface(desired, d.def, radius)

	if sNode and (not fNode or sDist <= fDist) then
		return self:_worldToBuild(CFrame.new(sCenter)), sParent, sNode, false
	elseif fNode then
		return self:_worldToBuild(CFrame.new(fCenter)), fParent, fNode, true
	end
	return self:_worldToBuild(CFrame.new(desired)), nil, nil, false
end

function VABController:_updateGhost()
	local d = self._drag
	if not d or not Workspace.CurrentCamera then
		return
	end
	local buildCF, parent, node, isSurface = self:_snapTarget()
	self._snap = { cf = buildCF, parent = parent, isSurface = isSurface }
	local worldCF = self:_buildToWorld(buildCF)
	d.ghost.CFrame = d.pod and worldCF or (worldCF * CFrame.Angles(0, 0, math.rad(90)))
	if node then
		self._node.CFrame = CFrame.new(node)
		self._node.Transparency = 0.2
	else
		self._node.Transparency = 1
	end
end

function VABController:_tryPickup()
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
			self:_beginDragExisting(idx)
		end
	end
end

function VABController:_onInputBegan(input, gameProcessed)
	if self._mode:GetMode() ~= "VAB" then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if gameProcessed or self._drag then
			return -- click landed on UI, or a drag is already running
		end
		self:_tryPickup()
	elseif input.KeyCode == Enum.KeyCode.Escape then
		self:_cancelDrag(true)
	elseif input.KeyCode == Enum.KeyCode.C then
		self:_toggleSnap()
	elseif input.KeyCode == Enum.KeyCode.X then
		local dec = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		self:_cycleSymmetry(dec and -1 or 1)
	elseif input.KeyCode == Enum.KeyCode.Delete or input.KeyCode == Enum.KeyCode.Backspace then
		if self._drag then
			self:_cancelDrag(false)
		elseif self._selected then
			self._vehicle:RemovePart(self._selected)
			self._selected = nil
		end
	end
end

-- ------------------------------------------------------------- panels ----

function VABController:_refresh()
	local parts = self._vehicle:GetParts()
	if self._selected and not parts[self._selected] then
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
	local def
	if self._drag then
		def = self._drag.def
	elseif self._selected then
		local p = self._vehicle:GetParts()[self._selected]
		def = p and p.def
	end
	if not def then
		self._partLabel.Text = "Hold + drag a part from the left,\nor a placed part, to move it."
		self._partLabel.TextColor3 = DIM
		self._removeBtn.Visible = false
		return
	end
	self._partLabel.TextColor3 = TEXT
	self._removeBtn.Visible = (self._selected ~= nil) and not self._drag
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
