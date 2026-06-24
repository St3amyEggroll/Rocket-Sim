--[[
	RenderScale
	Shared angular-size "pull-in" for the distant bodies (Planet / Moon / Sun).

	A body farther than the camera's draw range is pulled in along the line of sight and
	scaled by the same factor, so its on-screen size and direction are preserved exactly but
	it never distance-culls. Crucially the pulled render distance is a MONOTONIC function of
	the true distance, and ALL bodies share it -- so depth ordering (and therefore occlusion)
	is correct: the Sun, which is always far, ends up behind Terra and the Mun instead of
	punching through them.

	Within nearDist the body is drawn at its TRUE distance (scale 1) so streamed terrain and
	surfaces line up; beyond it the distance is compressed asymptotically toward maxDist.
]]

local RenderScale = {}

-- Returns (renderDist, scale) for a body at true camera distance `dist`.
function RenderScale.pull(dist, nearDist, maxDist)
	if dist <= nearDist or dist < 1e-3 then
		return dist, 1
	end
	-- maxDist - (maxDist-nearDist)*(nearDist/dist): == nearDist at dist=nearDist (continuous),
	-- -> maxDist as dist -> infinity, strictly increasing in dist (preserves depth order).
	local rd = maxDist - (maxDist - nearDist) * (nearDist / dist)
	return rd, rd / dist
end

return RenderScale
