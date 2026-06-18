--[[
	CrewController
	Owner of: the cosmetic avatar that rides the craft.

	The craft is a client-only, floating-origin kinematic object, so a normal
	server physics character can't ride it (it just falls). Instead we build a
	purely cosmetic, fully client-side avatar - the player's real Roblox
	appearance when available, otherwise a simple astronaut - anchor it, and
	re-pivot it onto the craft every frame. No physics, no falling.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CrewController = {}

function CrewController:Init()
	self._rider = nil
	self._riderHeight = Config.CRAFT.riderHeight
end

function CrewController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")
	local player = Players.LocalPlayer

	-- Make sure default controls don't capture input meant for the flight systems.
	task.spawn(function()
		local ok, controls = pcall(function()
			local scripts = player:WaitForChild("PlayerScripts", 10)
			local module = scripts and scripts:WaitForChild("PlayerModule", 10)
			return module and require(module):GetControls()
		end)
		if ok and controls then
			controls:Disable()
		end
	end)

	-- Build the rider asynchronously (avatar fetch yields).
	task.spawn(function()
		local model
		local ok = pcall(function()
			model = Players:CreateHumanoidModelFromUserId(player.UserId)
		end)
		if not ok or not model then
			model = self:_buildAstronaut()
		end
		self:_prepRider(model)
		model.Parent = Workspace
		self._rider = model
	end)

	Flight:GetUpdatedSignal():Connect(function(state)
		self:_ride(state)
	end)
end

function CrewController:_prepRider(model)
	model.Name = "Rider"

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.PlatformStand = true
		pcall(function()
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		end)
	end

	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BaseScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true -- client-only: this is reliable here
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			root = root or d
		end
	end
	model.PrimaryPart = root
end

function CrewController:_buildAstronaut()
	local model = Instance.new("Model")
	local function part(name, size, color, cf)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CFrame = cf
		p.Parent = model
		return p
	end

	local torso = part("Torso", Vector3.new(2.4, 3, 1.4), Color3.fromRGB(235, 238, 245), CFrame.new(0, 0, 0))
	part("Head", Vector3.new(1.6, 1.6, 1.6), Color3.fromRGB(235, 238, 245), CFrame.new(0, 2.3, 0))
	part("Visor", Vector3.new(1.2, 0.8, 0.4), Color3.fromRGB(90, 160, 220), CFrame.new(0, 2.4, -0.7))
	part("LeftLeg", Vector3.new(0.9, 2.4, 0.9), Color3.fromRGB(210, 214, 222), CFrame.new(-0.6, -2.4, 0))
	part("RightLeg", Vector3.new(0.9, 2.4, 0.9), Color3.fromRGB(210, 214, 222), CFrame.new(0.6, -2.4, 0))
	part("LeftArm", Vector3.new(0.8, 2.4, 0.8), Color3.fromRGB(210, 214, 222), CFrame.new(-1.6, 0, 0))
	part("RightArm", Vector3.new(0.8, 2.4, 0.8), Color3.fromRGB(210, 214, 222), CFrame.new(1.6, 0, 0))

	model.PrimaryPart = torso
	return model
end

function CrewController:_ride(state)
	local model = self._rider
	if not model or not model.PrimaryPart then
		return
	end

	local p = state.position
	local up = Vector3.new(p.x, p.y, p.z)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis

	local v = state.velocity
	local look = Vector3.new(v.x, v.y, v.z)
	if look.Magnitude < 1e-3 or math.abs(look.Unit:Dot(up)) > 0.99 then
		look = up:Cross(Vector3.xAxis)
		if look.Magnitude < 1e-3 then
			look = up:Cross(Vector3.zAxis)
		end
	end
	look = look.Unit

	local standPos = self._origin:ToRender(state.position) + up * self._riderHeight
	model:PivotTo(CFrame.lookAt(standPos, standPos + look, up))
end

return CrewController
