--[[
	DebugController
	A self-contained on-screen diagnostics overlay (top-right). It runs its own
	RenderStepped independent of the flight loop, so it reports the truth even if
	another system has failed:
	  * RS frames    -> the client render loop is alive (this overlay is updating)
	  * Flight upd   -> FlightController's per-frame loop is actually stepping
	  * model rows   -> whether the Body / Craft / Rider exist and where they are
	  * camera row   -> where the camera is and how far the planet/craft are
	Toggle with the ` (backtick) key.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local DebugController = {}

local function v3str(v)
	if not v then
		return "nil"
	end
	local x = v.x or v.X
	local y = v.y or v.Y
	local z = v.z or v.Z
	return string.format("%.0f, %.0f, %.0f", x, y, z)
end

local function modelPos(name)
	local m = Workspace:FindFirstChild(name)
	if not m then
		return name .. ": MISSING"
	end
	local cf = m:GetPivot()
	return string.format("%s: %.0f, %.0f, %.0f", name, cf.X, cf.Y, cf.Z)
end

function DebugController:Init()
	self._frames = 0
	self._enabled = true
end

function DebugController:Start()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "RocketSimDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Parent = player:WaitForChild("PlayerGui")

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(1, 0)
	label.Position = UDim2.new(1, -12, 0, 12)
	label.Size = UDim2.fromOffset(420, 300)
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.fromRGB(120, 255, 140)
	label.Font = Enum.Font.Code
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = "starting..."
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 6)
	pad.Parent = label
	self._label = label

	UserInputService.InputBegan:Connect(function(input, gp)
		if not gp and input.KeyCode == Enum.KeyCode.Backquote then
			self._enabled = not self._enabled
			gui.Enabled = self._enabled
		end
	end)

	RunService.RenderStepped:Connect(function()
		self._frames += 1
		if self._enabled then
			label.Text = self:_text()
		end
	end)
end

function DebugController:_text()
	local lines = { "BUILD P4.0 (debug)" }
	lines[#lines + 1] = "RS frames: " .. self._frames .. "   (` to hide)"

	local Flight = Registry:GetOrNil("FlightController")
	local Origin = Registry:GetOrNil("FloatingOriginController")
	local Input = Registry:GetOrNil("InputController")

	if Flight then
		local ok, s = pcall(function()
			return Flight:GetState()
		end)
		lines[#lines + 1] = "Flight upd: " .. tostring(Flight.GetUpdateCount and Flight:GetUpdateCount() or "?")
		if ok and s then
			local p = s.position
			local r = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
			lines[#lines + 1] = string.format("craft r: %.0f  alt: %.0f", r, r - (Flight:GetBodyRadius()))
			lines[#lines + 1] = "craft sim: " .. v3str(p)
			if Origin then
				lines[#lines + 1] = "origin:    " .. v3str(Origin:GetOrigin())
				lines[#lines + 1] = "craft rnd: " .. v3str(Origin:ToRender(p))
			end
		end
	else
		lines[#lines + 1] = "FlightController: MISSING"
	end

	if Input then
		lines[#lines + 1] = "map mode:  " .. tostring(Input:GetMapMode())
	end

	local Terrain = Registry:GetOrNil("TerrainController")
	if Terrain and Terrain.GetLODState then
		lines[#lines + 1] = "planet:    " .. Terrain:GetLODState()
	else
		lines[#lines + 1] = "planet:    Ball @ origin"
	end
	lines[#lines + 1] = modelPos("Craft")
	lines[#lines + 1] = modelPos("Rider")

	local cam = Workspace.CurrentCamera
	if cam then
		lines[#lines + 1] = string.format("cam type:  %s", cam.CameraType.Name)
		lines[#lines + 1] = "cam pos:   " .. v3str(cam.CFrame.Position)
		local craft = Workspace:FindFirstChild("Craft")
		if craft then
			lines[#lines + 1] = string.format("cam->craft:%.0f", (cam.CFrame.Position - craft:GetPivot().Position).Magnitude)
		end
	end

	return table.concat(lines, "\n")
end

return DebugController
