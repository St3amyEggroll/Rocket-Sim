--[[
	FloatingOriginController
	Owner of: the render origin offset (a double-precision sim Vec3).

	Keeps the active craft near render (0,0,0) by offsetting the entire rendered
	universe. Every sim -> render conversion in the project goes through here so
	the Roblox engine never sees huge coordinates.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Orbit = require(Shared:WaitForChild("OrbitMechanics"))
local Config = require(Shared:WaitForChild("Config"))
local Registry = require(Shared:WaitForChild("Registry"))

local FloatingOriginController = {}

function FloatingOriginController:Init()
	self._origin = Orbit.vec(0, 0, 0)
	self._threshold = Config.FLOATING_ORIGIN.rebaseThreshold
	self._nearRadius = Config.FLOATING_ORIGIN.nearRadius or 30000
	self._farMode = false
end

function FloatingOriginController:Start()
	-- Small world: keep the render origin fixed at the body centre so the fixed
	-- Terrain planet stays aligned (never rebase).
	self:SetOrigin(Orbit.vec(0, 0, 0))
end

-- Set the render origin to a sim position (stored as a copy).
function FloatingOriginController:SetOrigin(simVec)
	self._origin = Orbit.vec(simVec.x, simVec.y, simVec.z)
end

function FloatingOriginController:GetOrigin()
	return self._origin
end

-- Convert a double-precision sim position to a render-space Vector3.
function FloatingOriginController:ToRender(simVec): Vector3
	return Orbit.toVector3(simVec, self._origin)
end

-- Convert a render-space Vector3 back to a sim position.
function FloatingOriginController:ToSim(renderVec)
	return Orbit.fromVector3(renderVec, self._origin)
end

-- Rebase the origin onto the craft when it has drifted too far in render space.
-- Returns true when a rebase happened (render positions jump, but because every
-- rendered object uses this same origin in the same frame, nothing visibly pops).
function FloatingOriginController:UpdateFor(craftSimPos): boolean
	local renderPos = Orbit.toVector3(craftSimPos, self._origin)
	if renderPos.Magnitude > self._threshold then
		self:SetOrigin(craftSimPos)
		return true
	end
	return false
end

-- Two-mode origin policy keyed to the craft's distance from the body centre
-- (craftSimPos is Terra-centric):
--   NEAR Terra  -> origin pinned to the body centre (0), so the FIXED terrain and the
--                  biome shell -- which live at absolute world coords -- stay aligned.
--   FAR from it -> origin follows the craft, so deep-space (e.g. solar orbit) coords stay
--                  small and Roblox can render them without far-field jitter / culling.
-- Hysteresis (enter far above nearRadius, return near below 0.8x) avoids boundary flicker.
-- The snap is invisible because every renderer reads this same origin in the same frame.
function FloatingOriginController:UpdateForBody(craftSimPos)
	local r = math.sqrt(craftSimPos.x * craftSimPos.x + craftSimPos.y * craftSimPos.y + craftSimPos.z * craftSimPos.z)
	if self._farMode then
		if r < self._nearRadius * 0.8 then
			self._farMode = false
			self:SetOrigin(Orbit.vec(0, 0, 0))
		else
			self:SetOrigin(craftSimPos)
		end
	else
		if r > self._nearRadius then
			self._farMode = true
			self:SetOrigin(craftSimPos)
		else
			self:SetOrigin(Orbit.vec(0, 0, 0))
		end
	end
end

return FloatingOriginController
