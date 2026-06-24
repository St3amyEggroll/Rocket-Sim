--[[
	PartPreview
	ReplicatedStorage.Shared.PartPreview

	Builds small 3D models of parts and frames them in a ViewportFrame, so the parts
	palette and the staging panel can show real KSP-style part icons (instead of text or
	emoji). One geometry definition, shared by both panels.
]]

local PartPreview = {}

local SMOOTH = Enum.Material.SmoothPlastic
local METAL = Enum.Material.Metal
local DARK = Color3.fromRGB(40, 42, 48)
local STEEL = Color3.fromRGB(150, 150, 158)

local function part(model, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = model
	return p
end

-- A cylinder whose length runs along +Y (the build axis), centred at height y.
local function cyl(model, h, r, color, mat, y)
	return part(model, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(h, r * 2, r * 2),
		Color = color,
		Material = mat or SMOOTH,
		CFrame = CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
	})
end

local function ball(model, sx, sy, sz, color, mat, y)
	return part(model, {
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(sx, sy, sz),
		Color = color,
		Material = mat or SMOOTH,
		CFrame = CFrame.new(0, y, 0),
	})
end

local function block(model, size, color, mat, cf)
	return part(model, { Shape = Enum.PartType.Block, Size = size, Color = color, Material = mat or SMOOTH, CFrame = cf })
end

-- A thin rod between two points (for the radial decoupler's support struts).
local function rod(model, a, b, thick, color)
	local len = (b - a).Magnitude
	if len < 1e-3 then
		return
	end
	return part(model, {
		Shape = Enum.PartType.Block,
		Size = Vector3.new(thick, thick, len),
		Color = color,
		Material = METAL,
		CFrame = CFrame.lookAt((a + b) * 0.5, b),
	})
end

-- Build a part's geometry into `model`, centred at the origin, standing along +Y.
function PartPreview.geometry(model, def)
	local r = def.radius or 1
	local h = math.max(def.height or 0, 1)
	local sh = def.shape

	if sh == "pod" then
		cyl(model, h * 0.7, r, def.color, SMOOTH, -h * 0.08) -- wide lower body
		cyl(model, h * 0.42, r * 0.6, def.color, SMOOTH, h * 0.42) -- narrowed top (taper)
		ball(model, r * 1.05, r * 0.75, r * 1.05, def.color, SMOOTH, h * 0.62) -- rounded nose
		cyl(model, h * 0.12, r * 1.05, Color3.fromRGB(58, 48, 44), SMOOTH, -h * 0.5) -- heat shield
	elseif sh == "engine" then
		cyl(model, h * 0.72, r * 0.86, def.color, METAL, h * 0.12) -- body
		cyl(model, h * 0.2, r * 0.5, DARK, METAL, -h * 0.34) -- nozzle throat
		cyl(model, h * 0.16, r * 0.74, DARK, METAL, -h * 0.5) -- flared bell
	elseif sh == "nose" then
		-- A streamlined nose cap: a short base ring + an ogive (a stretched dome) that seats on
		-- the part below (bottom ~ -h/2) and tapers to a point above.
		cyl(model, h * 0.2, r, def.color, SMOOTH, -h * 0.4)
		ball(model, r * 2, h * 1.3, r * 2, def.color, SMOOTH, h * 0.15)
	elseif sh == "parachute" then
		cyl(model, h, r, def.color, SMOOTH, -h * 0.1)
		ball(model, r * 1.5, r * 0.8, r * 1.5, Color3.fromRGB(220, 96, 76), SMOOTH, h * 0.45)
	elseif sh == "decoupler" then
		if def.radial then
			-- KSP-style radial decoupler: a flat black mount, a yellow indicator, and gray
			-- support struts splaying out. Built along +X (= outward when placed on a craft).
			block(model, Vector3.new(0.7, 2.4, 1.3), Color3.fromRGB(26, 26, 30), SMOOTH, CFrame.new(0.15, 0, 0))
			block(model, Vector3.new(0.24, 0.55, 0.55), Color3.fromRGB(236, 190, 40), SMOOTH, CFrame.new(0.5, 0.35, 0))
			block(model, Vector3.new(0.24, 0.55, 0.55), Color3.fromRGB(20, 20, 24), SMOOTH, CFrame.new(0.5, -0.45, 0))
			local arm = STEEL
			local function strut(y2, z2)
				rod(model, Vector3.new(0.12, y2 * 0.35, 0), Vector3.new(0.14, y2, z2), 0.16, arm)
				block(model, Vector3.new(0.34, 0.34, 0.34), arm, METAL, CFrame.new(0.14, y2, z2))
			end
			strut(1.45, 1.05)
			strut(1.45, -1.05)
			strut(-1.45, 1.05)
			strut(-1.45, -1.05)
		else
			local dh = math.max(h, 0.8)
			cyl(model, dh, r, def.color, METAL, 0)
			cyl(model, dh * 0.42, r * 1.04, Color3.fromRGB(232, 184, 44), METAL, 0) -- yellow band
		end
	elseif sh == "fins" then
		cyl(model, 2.6, r * 0.4, STEEL, METAL, 0)
		for i = 0, 2 do
			local a = i * (2 * math.pi / 3)
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			block(model, Vector3.new(r * 1.3, 2.4, 0.28), def.color, METAL, CFrame.fromMatrix(dir * (r * 0.7), dir, Vector3.yAxis))
		end
	elseif sh == "leg" then
		block(model, Vector3.new(r * 1.1, 1.3, r * 0.7), def.color, METAL, CFrame.new(0, 0.6, 0)) -- mount
		block(model, Vector3.new(0.32, 2.8, 0.32), STEEL, METAL, CFrame.new(0.7, -0.7, 0) * CFrame.Angles(0, 0, math.rad(26))) -- strut
		block(model, Vector3.new(1.5, 0.32, 0.8), DARK, SMOOTH, CFrame.new(1.25, -2.0, 0)) -- foot
	else
		-- fuel tank: body + thin end rings for detail
		cyl(model, h, r, def.color, SMOOTH, 0)
		cyl(model, math.max(h * 0.05, 0.2), r * 1.02, STEEL, METAL, h * 0.5 - 0.12)
		cyl(model, math.max(h * 0.05, 0.2), r * 1.02, STEEL, METAL, -h * 0.5 + 0.12)
	end
end

-- A ViewportFrame showing the part, framed by a 3/4 camera. The caller sets Size /
-- Position / Parent.
function PartPreview.thumbnail(def)
	local vf = Instance.new("ViewportFrame")
	vf.BackgroundColor3 = Color3.fromRGB(13, 15, 21)
	vf.BorderSizePixel = 0
	vf.Ambient = Color3.fromRGB(150, 152, 162)
	vf.LightColor = Color3.fromRGB(255, 252, 244)
	vf.LightDirection = Vector3.new(-1, -1.2, -0.7)

	local model = Instance.new("Model")
	PartPreview.geometry(model, def)
	model.Parent = vf

	local cam = Instance.new("Camera")
	cam.FieldOfView = 24
	cam.Parent = vf
	vf.CurrentCamera = cam

	local span = math.max(def.height or 0, (def.radius or 1) * 2, 1.5)
	local dir = Vector3.new(0.6, 0.4, 1).Unit
	cam.CFrame = CFrame.lookAt(dir * (span * 3.0 + 3), Vector3.zero)
	return vf
end

return PartPreview
