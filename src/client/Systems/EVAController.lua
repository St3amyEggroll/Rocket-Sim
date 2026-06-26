--[[
	EVAController
	A controllable kerbal on the surface. While LANDED you can EVA: a kerbal steps out of the
	craft and you walk it over the surface (WASD relative to the camera), hop with a jetpack (a
	finite monopropellant budget), take a surface SAMPLE (science), PLANT a flag (persistent),
	and BOARD to climb back in.

	The kerbal IS the player's real Roblox avatar (the same Humanoid rig the crew rider uses,
	fetched with Players:CreateHumanoidModelFromUserId), with its walk animation played while
	moving. The craft sim is custom (floating origin, spherical gravity), so the avatar is moved
	KINEMATICALLY rather than by Humanoid physics: only its root is anchored and we snap it to the
	local surface and align it to local-up each frame, which is robust anywhere on the planet (a
	physics Humanoid walks toward world -Y and would tip over off the equator). The limbs stay
	jointed so the animation still plays. State lives in the body-relative sim frame and renders
	through the floating origin, exactly like the craft. (A blocky stand-in is used only if the
	avatar fetch fails.)

	Entered/left via GameMode "EVA"; the craft stays parked where it landed (FlightController
	skips its reset for EVA <-> Flight). Flags + crew mirror the server's State push.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))
local Planet = require(Shared:WaitForChild("Planet"))
local Situations = require(Shared:WaitForChild("Situations"))
local Science = require(Shared:WaitForChild("Science"))

local EVAController = {}

local WALK_SPEED = 12 -- studs/s on foot
local JET_FACTOR = 1.9 -- jetpack thrust as a multiple of local gravity
local MONO_MAX = 100
local JET_DRAIN = 22 -- monoprop/s while jetpacking
local FOOT = 2.4 -- kerbal centre height above the surface
local BOARD_DIST = 26 -- must be within this of the craft to board

local function frameFromUp(pos, up, fwd)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis
	fwd = fwd - up * fwd:Dot(up)
	if fwd.Magnitude < 1e-3 then
		local ref = (math.abs(up.Y) < 0.99) and Vector3.yAxis or Vector3.xAxis
		fwd = up:Cross(ref)
	end
	return CFrame.lookAt(pos, pos + fwd.Unit, up)
end

local function bodyMuR(bodyId)
	if bodyId == "moon" then
		return Config.MOON.mu, Config.MOON.radius
	end
	return Config.BODY.mu, Config.BODY.radius
end

-- Surface radius beneath a unit direction on the active body.
local function surfaceR(bodyId, dir)
	if bodyId == "moon" then
		return Config.MOON.radius
	end
	return Planet.radiusForUnit(dir.X, dir.Y, dir.Z)
end

function EVAController:Init()
	self._crew = {}
	self._flags = {}
	self._mono = MONO_MAX
	self._footH = FOOT -- pivot height above the surface (recomputed for the real avatar)
end

function EVAController:Start()
	self._mode = Registry:Get("GameModeController")
	self._origin = Registry:Get("FloatingOriginController")
	self._flight = Registry:Get("FlightController")

	local remotes = ReplicatedStorage:WaitForChild("GameRemotes", 10)
	if remotes then
		self._stateEv = remotes:WaitForChild("State")
		self._plantEv = remotes:WaitForChild("PlantFlag")
		self._sampleEv = remotes:WaitForChild("RunExperiment")
		self._stateEv.OnClientEvent:Connect(function(state)
			if type(state) == "table" then
				self._crew = state.crew or {}
				self._flags = state.flags or {}
			end
		end)
		self._stateEv:FireServer() -- request our profile (crew + flags)
	end

	-- Use the player's real Roblox avatar as the kerbal. The fetch yields, so start with a blocky
	-- stand-in immediately and swap to the avatar once it loads.
	self._kerbal = self:_buildKerbal()
	self._kerbal.Parent = nil
	task.spawn(function()
		local model
		local ok = pcall(function()
			model = Players:CreateHumanoidModelFromUserId(Players.LocalPlayer.UserId)
		end)
		if ok and model then
			self:_prepAvatar(model)
			self._footH = self:_measureFootH(model)
			local old = self._kerbal
			self._kerbal = model
			model.Parent = self._active and Workspace or nil
			if old and old ~= model then
				old:Destroy()
			end
		end
	end)

	self._flagFolder = Instance.new("Folder")
	self._flagFolder.Name = "Flags"
	self._flagFolder.Parent = Workspace
	self._flagPool = {}

	self:_buildHUD(Players.LocalPlayer:WaitForChild("PlayerGui"))

	self._mode.ModeChanged:Connect(function(m)
		if m == "EVA" then
			self:_enter()
		else
			self:_exit()
		end
	end)

	self._flight:GetUpdatedSignal():Connect(function(state, info)
		self._info = info
		self._craftState = state
		self:_renderFlags(info)
	end)

	RunService:BindToRenderStep("RocketSim_EVA", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if self._active then
			self:_step(math.min(dt, 0.1))
		end
	end)
end

-- True if the craft can EVA right now (landed on a body with crew aboard).
function EVAController:CanEVA()
	local info = self._info
	if not info or info.mode ~= "Flight" or info.status ~= "Landed" then
		return false
	end
	if info.bodyId ~= "planet" and info.bodyId ~= "moon" then
		return false
	end
	return #self._crew > 0
end

function EVAController:_enter()
	if not self._craftState or not self._info then
		return
	end
	self._active = true
	self._mono = MONO_MAX
	self._evaVr = 0
	self._bodyId = self._info.bodyId
	self._crewName = (self._crew[1] and self._crew[1].name) or "Kerbal"

	-- Step out a few studs to the side of the craft, on the surface.
	local cp = self._craftState.position
	local pos = Vector3.new(cp.x, cp.y, cp.z)
	local up = (pos.Magnitude > 1e-3) and pos.Unit or Vector3.yAxis
	local side = up:Cross(Vector3.yAxis)
	side = (side.Magnitude > 1e-3) and side.Unit or up:Cross(Vector3.xAxis).Unit
	local dir = (pos + side * 8).Unit
	local r = surfaceR(self._bodyId, dir) + self._footH
	self._evaPos = Orbit.vec(dir.X * r, dir.Y * r, dir.Z * r)
	self._facing = side

	if self._kerbal then
		self._kerbal.Parent = Workspace
	end
	self._gui.Enabled = true
	self._title.Text = "EVA — " .. self._crewName
end

function EVAController:_exit()
	self._active = false
	if self._walkTrack and self._walkTrack.IsPlaying then
		pcall(function()
			self._walkTrack:Stop()
		end)
	end
	if self._kerbal then
		self._kerbal.Parent = nil
	end
	self._gui.Enabled = false
end

function EVAController:_step(dt)
	if not self._kerbal then
		return
	end
	local pos = Vector3.new(self._evaPos.x, self._evaPos.y, self._evaPos.z)
	local r = pos.Magnitude
	local up = (r > 1e-3) and pos.Unit or Vector3.yAxis
	local cam = Workspace.CurrentCamera

	-- Move basis from the camera, flattened onto the local horizon.
	local look = cam and cam.CFrame.LookVector or Vector3.zAxis
	local fwd = look - up * look:Dot(up)
	fwd = (fwd.Magnitude > 1e-3) and fwd.Unit or up:Cross(Vector3.xAxis).Unit
	local right = fwd:Cross(up)

	local fb = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local lr = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	local move = fwd * fb + right * lr
	if move.Magnitude > 1e-3 then
		self._facing = move.Unit
		pos = (pos + move.Unit * WALK_SPEED * dt)
		pos = pos.Unit * r -- walking keeps the current radius (snapped below)
		up = pos.Unit
	end

	-- Radial: jetpack up (drains monoprop) or gravity down; rest on the surface.
	local mu, _ = bodyMuR(self._bodyId)
	local g = mu / math.max(r * r, 1)
	local jet = UserInputService:IsKeyDown(Enum.KeyCode.Space) and self._mono > 0
	if jet then
		self._evaVr = (self._evaVr or 0) + g * JET_FACTOR * dt
		self._mono = math.max(0, self._mono - JET_DRAIN * dt)
	else
		self._evaVr = (self._evaVr or 0) - g * dt
	end
	local newR = r + self._evaVr * dt
	local ground = surfaceR(self._bodyId, pos.Unit) + self._footH
	if newR <= ground then
		newR = ground
		self._evaVr = 0
		if not jet then
			self._mono = math.min(MONO_MAX, self._mono + 6 * dt) -- slowly refill on the ground
		end
	end
	pos = pos.Unit * newR
	self._evaPos = Orbit.vec(pos.X, pos.Y, pos.Z)

	-- Render through the floating origin (body-relative -> Terra-centric -> render).
	local bc = (self._info and self._info.bodyCenter) or Orbit.vec(0, 0, 0)
	local abs = Orbit.vec(pos.X + bc.x, pos.Y + bc.y, pos.Z + bc.z)
	self._evaRender = self._origin:ToRender(abs)
	self._evaUp = pos.Unit
	self._kerbal:PivotTo(frameFromUp(self._evaRender, pos.Unit, self._facing or fwd))
	self:_setWalking(move.Magnitude > 1e-3)

	self._monoFill.Size = UDim2.new(self._mono / MONO_MAX, 0, 1, 0)
end

-- Play/stop the avatar's walk loop based on whether it's moving (no-op for the blocky stand-in).
function EVAController:_setWalking(moving)
	local t = self._walkTrack
	if not t then
		return
	end
	if moving and not t.IsPlaying then
		t:Play(0.15)
	elseif not moving and t.IsPlaying then
		t:Stop(0.15)
	end
end

-- For the camera (chase the kerbal).
function EVAController:GetEvaRender()
	return self._active and self._evaRender or nil
end
function EVAController:GetEvaUp()
	return self._evaUp or Vector3.yAxis
end

-- ---------------------------------------------------------------- actions ----

function EVAController:_board()
	self._mode:SetMode("Flight")
end

function EVAController:_plantFlag()
	if not self._active or not self._evaPos then
		return
	end
	if self._plantEv then
		self._plantEv:FireServer({
			name = self._crewName .. "'s Flag",
			bodyId = self._bodyId,
			pos = { x = self._evaPos.x, y = self._evaPos.y, z = self._evaPos.z },
		})
	end
	self:_toast("Flag planted!")
end

function EVAController:_sample()
	if not self._active or not self._evaPos then
		return
	end
	local mu, R = bodyMuR(self._bodyId)
	local ctx = Situations.of(
		{ position = self._evaPos, velocity = Orbit.vec(0, 0, 0) },
		{ bodyId = self._bodyId, bodyRadius = R, mu = mu, status = "Landed", mode = "Flight" }
	)
	if not ctx then
		return
	end
	if self._sampleEv then
		self._sampleEv:FireServer({ exp = "evaSample", body = ctx.body, biome = ctx.biome, situation = ctx.situation })
	end
	local val = Science.value("evaSample", ctx.body, ctx.situation)
	self:_toast(("Surface sample  (+%d sci if new)"):format(val))
end

-- ---------------------------------------------------------------- visuals ----

local function block(parent, size, color, cf, mat)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- Prepare the player's real avatar for kinematic EVA: only the root is anchored (so the limbs
-- stay jointed and can animate), collisions/queries off, the Humanoid state machine frozen, and
-- a rig-appropriate walk loop loaded that _setWalking plays while moving. Default Animate scripts
-- are removed so they don't fight the manual track.
function EVAController:_prepAvatar(model)
	model.Name = "EVAKerbal"
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	model.PrimaryPart = root
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.AutoRotate = false
		pcall(function()
			hum.EvaluateStateMachine = false
		end)
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BaseScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = (d == root) -- only the root is anchored; limbs follow via Motor6D + animation
		end
	end
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		local anim = Instance.new("Animation")
		-- Roblox default walk animations (rig-appropriate).
		anim.AnimationId = (hum.RigType == Enum.HumanoidRigType.R6) and "rbxassetid://180426354"
			or "rbxassetid://913376220"
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and track then
			track.Looped = true
			self._walkTrack = track
		end
	end
end

-- Distance from the avatar's pivot (its HumanoidRootPart, at mid-torso) down to its feet, so we
-- can rest its feet -- not its waist -- on the surface.
function EVAController:_measureFootH(model)
	local ok, half = pcall(function()
		model:PivotTo(CFrame.new()) -- stand upright at the origin to measure axis-aligned extents
		return model:GetExtentsSize().Y * 0.5
	end)
	if ok and half and half > 0.5 then
		return half
	end
	return FOOT
end

-- A small blocky astronaut, built in a local frame (feet at y=0, +Y up, facing +Z(look)).
function EVAController:_buildKerbal()
	local m = Instance.new("Model")
	m.Name = "EVAKerbal"
	local SUIT = Color3.fromRGB(236, 238, 244)
	local VISOR = Color3.fromRGB(40, 60, 90)
	local PACK = Color3.fromRGB(150, 154, 162)
	local root = block(m, Vector3.new(0.2, 0.2, 0.2), SUIT, CFrame.new(0, 0, 0))
	root.Transparency = 1
	m.PrimaryPart = root
	block(m, Vector3.new(0.6, 1.6, 0.5), SUIT, CFrame.new(-0.45, 0.8, 0)) -- left leg
	block(m, Vector3.new(0.6, 1.6, 0.5), SUIT, CFrame.new(0.45, 0.8, 0)) -- right leg
	block(m, Vector3.new(1.5, 1.7, 0.9), SUIT, CFrame.new(0, 2.4, 0)) -- torso
	block(m, Vector3.new(1.0, 0.7, 0.55), PACK, CFrame.new(0, 2.4, -0.7)) -- backpack
	block(m, Vector3.new(0.5, 1.4, 0.45), SUIT, CFrame.new(-1.0, 2.5, 0)) -- left arm
	block(m, Vector3.new(0.5, 1.4, 0.45), SUIT, CFrame.new(1.0, 2.5, 0)) -- right arm
	local head = block(m, Vector3.new(1.0, 1.0, 1.0), SUIT, CFrame.new(0, 3.7, 0)) -- helmet
	head.Shape = Enum.PartType.Ball
	local visor = block(m, Vector3.new(0.7, 0.55, 0.45), VISOR, CFrame.new(0, 3.7, 0.45)) -- visor
	visor.Material = Enum.Material.Glass
	return m
end

function EVAController:_flagModel()
	local m = Instance.new("Model")
	block(m, Vector3.new(0.2, 0.2, 0.2), Color3.fromRGB(255, 255, 255), CFrame.new()).Transparency = 1
	m.PrimaryPart = m:GetChildren()[1]
	block(m, Vector3.new(0.25, 6, 0.25), Color3.fromRGB(190, 192, 198), CFrame.new(0, 3, 0), Enum.Material.Metal) -- pole
	block(m, Vector3.new(0.1, 1.8, 3), Color3.fromRGB(90, 170, 255), CFrame.new(0, 5, 1.6)) -- banner
	return m
end

-- Render persisted flags for the current body, near the craft (pooled).
function EVAController:_renderFlags(info)
	if not info or info.mapMode or info.isMenu or (info.mode ~= "Flight" and info.mode ~= "EVA") then
		for _, f in ipairs(self._flagPool) do
			if f.model.Parent then
				f.model.Parent = nil
			end
		end
		return
	end
	local bc = info.bodyCenter or Orbit.vec(0, 0, 0)
	local shown = 0
	for _, flag in ipairs(self._flags) do
		if flag.bodyId == info.bodyId and flag.pos then
			local p = Vector3.new(flag.pos.x, flag.pos.y, flag.pos.z)
			local craft = self._craftState and self._craftState.position
			local near = not craft
				or (p - Vector3.new(craft.x, craft.y, craft.z)).Magnitude < (Config.DOCKING and 4000 or 4000)
			if near then
				shown += 1
				local f = self._flagPool[shown]
				if not f then
					local model = self:_flagModel()
					f = { model = model }
					self._flagPool[shown] = f
				end
				if f.model.Parent ~= self._flagFolder then
					f.model.Parent = self._flagFolder
				end
				local abs = Orbit.vec(p.X + bc.x, p.Y + bc.y, p.Z + bc.z)
				local up = (p.Magnitude > 1e-3) and p.Unit or Vector3.yAxis
				f.model:PivotTo(frameFromUp(self._origin:ToRender(abs), up, up:Cross(Vector3.yAxis)))
			end
		end
	end
	for i = shown + 1, #self._flagPool do
		if self._flagPool[i].model.Parent then
			self._flagPool[i].model.Parent = nil
		end
	end
end

-- ---------------------------------------------------------------- HUD ----

function EVAController:_buildHUD(pg)
	local gui = Instance.new("ScreenGui")
	gui.Name = "EVAHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 64
	gui.Enabled = false
	gui.Parent = pg
	self._gui = gui

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -14)
	bar.Size = UDim2.fromOffset(440, 84)
	bar.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	bar.BackgroundTransparency = 0.15
	bar.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = bar
	bar.Parent = gui

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(12, 8)
	title.Size = UDim2.fromOffset(300, 18)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(150, 235, 170)
	title.Text = "EVA"
	title.Parent = bar
	self._title = title

	-- Monoprop (jetpack) gauge.
	local label = Instance.new("TextLabel")
	label.Position = UDim2.fromOffset(12, 28)
	label.Size = UDim2.fromOffset(70, 14)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(150, 200, 230)
	label.Text = "Jetpack"
	label.Parent = bar
	local track = Instance.new("Frame")
	track.Position = UDim2.fromOffset(84, 29)
	track.Size = UDim2.fromOffset(160, 12)
	track.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
	track.BorderSizePixel = 0
	track.Parent = bar
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(90, 170, 255)
	fill.BorderSizePixel = 0
	fill.Parent = track
	self._monoFill = fill

	local function btn(text, x, w, color)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(0, 1)
		b.Position = UDim2.new(0, x, 1, -10)
		b.Size = UDim2.fromOffset(w, 30)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.Text = text
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0, 6)
		cc.Parent = b
		b.Parent = bar
		return b
	end
	btn("Take Sample", 12, 130, Color3.fromRGB(60, 140, 90)).Activated:Connect(function()
		self:_sample()
	end)
	btn("Plant Flag", 150, 120, Color3.fromRGB(60, 110, 160)).Activated:Connect(function()
		self:_plantFlag()
	end)
	btn("Board", 278, 150, Color3.fromRGB(70, 76, 90)).Activated:Connect(function()
		self:_board()
	end)

	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -12, 0, 28)
	hint.Size = UDim2.fromOffset(180, 14)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.TextColor3 = Color3.fromRGB(150, 158, 170)
	hint.Text = "WASD move • Space jetpack"
	hint.Parent = bar
	self._hint = hint
	self._toastToken = 0
end

function EVAController:_toast(text)
	if not self._title then
		return
	end
	self._title.Text = text
	self._toastToken += 1
	local token = self._toastToken
	task.delay(2.5, function()
		if self._toastToken == token and self._title then
			self._title.Text = "EVA — " .. (self._crewName or "Kerbal")
		end
	end)
end

return EVAController
