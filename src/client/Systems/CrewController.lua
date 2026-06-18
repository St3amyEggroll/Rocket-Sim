--[[
	CrewController
	Owner of: seating the player's Roblox avatar on the kinematic craft.

	The craft's motion comes from OrbitMechanics, not Roblox physics, so the
	avatar can't be driven by the engine's character controller. Instead we
	anchor the avatar and re-pivot it onto the craft every frame, oriented with
	"up" = radial-out and facing prograde. Default walk/jump controls are
	disabled so input goes to the flight systems.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local CrewController = {}

function CrewController:Init()
	self._char = nil
	self._riderHeight = Config.CRAFT.riderHeight
end

function CrewController:Start()
	self._origin = Registry:Get("FloatingOriginController")
	local Flight = Registry:Get("FlightController")
	local player = Players.LocalPlayer

	-- Hand input over to the flight systems by disabling default controls.
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

	if player.Character then
		task.spawn(function()
			self:_setupCharacter(player.Character)
		end)
	end
	player.CharacterAdded:Connect(function(char)
		self:_setupCharacter(char)
	end)

	Flight:GetUpdatedSignal():Connect(function(state)
		self:_ride(state)
	end)
end

function CrewController:_setupCharacter(char)
	local humanoid = char:WaitForChild("Humanoid", 10)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root then
		return
	end

	humanoid.PlatformStand = true
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false
	humanoid.BreakJointsOnDeath = false

	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
		end
	end

	root.Anchored = true
	char.PrimaryPart = root
	self._char = char
end

function CrewController:_ride(state)
	local char = self._char
	if not char or not char.PrimaryPart or not char.Parent then
		return
	end

	local craftRender = self._origin:ToRender(state.position)

	-- "Up" away from the body; facing prograde.
	local p = state.position
	local up = Vector3.new(p.x, p.y, p.z)
	up = (up.Magnitude > 1e-3) and up.Unit or Vector3.yAxis

	local v = state.velocity
	local look = Vector3.new(v.x, v.y, v.z)
	look = (look.Magnitude > 1e-3) and look.Unit or up:Cross(Vector3.xAxis)

	-- Keep look perpendicular-ish to up so CFrame.lookAt stays well-defined.
	if math.abs(look:Dot(up)) > 0.99 then
		look = up:Cross(Vector3.xAxis)
		if look.Magnitude < 1e-3 then
			look = up:Cross(Vector3.zAxis)
		end
		look = look.Unit
	end

	local standPos = craftRender + up * self._riderHeight
	char:PivotTo(CFrame.lookAt(standPos, standPos + look, up))
end

return CrewController
