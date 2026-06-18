--!nonstrict
--[[
	OrbitMechanics
	ReplicatedStorage.Shared.OrbitMechanics

	IMPORTANT (read me):
	  This file is a faithful, self-contained implementation of the documented
	  OrbitMechanics API. It was generated because the repository did not yet
	  contain the "validated" module the design brief referred to. The public
	  surface below matches the documented signatures exactly, so if/when you
	  have your own validated core, you can drop it in here without touching any
	  other file in the project.

	Conventions:
	  * The central body sits at the SIM origin (0,0,0). All positions/velocities
	    are body-centred, double-precision Lua-number tables (never Vector3).
	  * Units are arbitrary but must be self-consistent: studs for distance,
	    seconds for time, mu in studs^3 / second^2.
	  * Only toVector3 / fromVector3 cross the render boundary (Vector3).

	Math:
	  * gravityAccel / integrate -> Newtonian point-mass gravity, RK4 step.
	  * propagate -> analytic two-body (Kepler) propagation via the universal
	    variable formulation with Stumpff functions (handles elliptic, parabolic
	    and hyperbolic orbits, and forward or backward dt).
]]

local Orbit = {}

export type Vec3 = { x: number, y: number, z: number }
export type State = { position: Vec3, velocity: Vec3 }
export type Readout = {
	semiMajorAxis: number,
	eccentricity: number,
	periapsis: number,
	apoapsis: number,
	period: number,
	specificEnergy: number,
	speed: number,
	altitude: number,
}

-- Localise hot math functions.
local sqrt = math.sqrt
local sin = math.sin
local cos = math.cos
local exp = math.exp
local abs = math.abs
local log = math.log
local huge = math.huge
local pi = math.pi

-- Hyperbolic helpers (math.cosh / math.sinh are not available in Luau).
local function coshx(x: number): number
	local e = exp(x)
	return (e + 1 / e) * 0.5
end

local function sinhx(x: number): number
	local e = exp(x)
	return (e - 1 / e) * 0.5
end

----------------------------------------------------------------------
-- Internal Vec3 helpers (plain tables, double precision).
----------------------------------------------------------------------

local function vec(x: number, y: number, z: number): Vec3
	return { x = x, y = y, z = z }
end

local function vcopy(a: Vec3): Vec3
	return { x = a.x, y = a.y, z = a.z }
end

local function vadd(a: Vec3, b: Vec3): Vec3
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

local function vsub(a: Vec3, b: Vec3): Vec3
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function vscale(a: Vec3, s: number): Vec3
	return { x = a.x * s, y = a.y * s, z = a.z * s }
end

local function vdot(a: Vec3, b: Vec3): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vcross(a: Vec3, b: Vec3): Vec3
	return {
		x = a.y * b.z - a.z * b.y,
		y = a.z * b.x - a.x * b.z,
		z = a.x * b.y - a.y * b.x,
	}
end

local function vmag(a: Vec3): number
	return sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

----------------------------------------------------------------------
-- Stumpff functions c2(psi), c3(psi).
----------------------------------------------------------------------

local function stumpff(psi: number): (number, number)
	local c2, c3
	if psi > 1e-6 then
		local s = sqrt(psi)
		c2 = (1 - cos(s)) / psi
		c3 = (s - sin(s)) / (s * s * s)
	elseif psi < -1e-6 then
		local s = sqrt(-psi)
		c2 = (coshx(s) - 1) / (-psi)
		c3 = (sinhx(s) - s) / (s * s * s)
	else
		-- Series expansion around psi = 0 (covers the parabolic limit).
		c2 = 0.5 - psi / 24 + (psi * psi) / 720
		c3 = 1 / 6 - psi / 120 + (psi * psi) / 5040
	end
	return c2, c3
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

-- Construct a Vec3.
function Orbit.vec(x: number, y: number, z: number): Vec3
	return vec(x, y, z)
end

-- Gravitational acceleration toward the body at the sim origin.
function Orbit.gravityAccel(pos: Vec3, mu: number): Vec3
	local r = vmag(pos)
	if r < 1e-9 then
		return vec(0, 0, 0)
	end
	local k = -mu / (r * r * r)
	return vec(pos.x * k, pos.y * k, pos.z * k)
end

-- POWERED step: RK4 integration of gravity plus an optional extra acceleration
-- (thrust, drag, ...). extraAccel(pos, vel) -> Vec3. Call every frame.
function Orbit.integrate(state: State, mu: number, dt: number, extraAccel: ((Vec3, Vec3) -> Vec3)?): State
	if dt == 0 then
		return { position = vcopy(state.position), velocity = vcopy(state.velocity) }
	end

	local function accel(pos: Vec3, vel: Vec3): Vec3
		local g = Orbit.gravityAccel(pos, mu)
		if extraAccel then
			local e = extraAccel(pos, vel)
			if e then
				return vadd(g, e)
			end
		end
		return g
	end

	local p0 = state.position
	local v0 = state.velocity
	local h = dt
	local h2 = dt * 0.5

	-- k1
	local k1p = v0
	local k1v = accel(p0, v0)

	-- k2
	local p2 = vadd(p0, vscale(k1p, h2))
	local v2 = vadd(v0, vscale(k1v, h2))
	local k2p = v2
	local k2v = accel(p2, v2)

	-- k3
	local p3 = vadd(p0, vscale(k2p, h2))
	local v3 = vadd(v0, vscale(k2v, h2))
	local k3p = v3
	local k3v = accel(p3, v3)

	-- k4
	local p4 = vadd(p0, vscale(k3p, h))
	local v4 = vadd(v0, vscale(k3v, h))
	local k4p = v4
	local k4v = accel(p4, v4)

	local sixth = h / 6
	local newPos = vadd(p0, vscale(vadd(vadd(k1p, vscale(k2p, 2)), vadd(vscale(k3p, 2), k4p)), sixth))
	local newVel = vadd(v0, vscale(vadd(vadd(k1v, vscale(k2v, 2)), vadd(vscale(k3v, 2), k4v)), sixth))

	return { position = newPos, velocity = newVel }
end

-- COASTING step: analytic Kepler propagation. Engine-off + time warp friendly
-- because dt can be any size (forward or backward).
function Orbit.propagate(state: State, mu: number, dt: number): State
	if dt == 0 then
		return { position = vcopy(state.position), velocity = vcopy(state.velocity) }
	end

	local r0vec = state.position
	local v0vec = state.velocity
	local r0 = vmag(r0vec)
	local v0 = vmag(v0vec)
	local rdotv = vdot(r0vec, v0vec)
	local sqrtmu = sqrt(mu)

	-- alpha = 1/a  (>0 ellipse, =0 parabola, <0 hyperbola)
	local alpha = 2 / r0 - (v0 * v0) / mu

	-- Initial guess for the universal anomaly chi.
	local chi
	if alpha > 1e-9 then
		chi = sqrtmu * dt * alpha
	elseif alpha < -1e-9 then
		local a = 1 / alpha
		local s = (dt >= 0) and 1 or -1
		local denom = rdotv + s * sqrt(-mu * a) * (1 - r0 * alpha)
		local arg = (-2 * mu * alpha * dt) / denom
		if denom == 0 or arg <= 0 then
			chi = (sqrtmu * dt) / r0
		else
			chi = s * sqrt(-a) * log(arg)
		end
	else
		chi = (sqrtmu * dt) / r0
	end

	-- Newton-Raphson on the universal Kepler equation.
	local r = r0
	for _ = 1, 200 do
		local psi = chi * chi * alpha
		local c2, c3 = stumpff(psi)
		r = chi * chi * c2 + (rdotv / sqrtmu) * chi * (1 - psi * c3) + r0 * (1 - psi * c2)
		local F = (rdotv / sqrtmu) * chi * chi * c2
			+ (1 - alpha * r0) * chi * chi * chi * c3
			+ r0 * chi
			- sqrtmu * dt
		if abs(r) < 1e-12 then
			break
		end
		local dchi = F / r
		chi = chi - dchi
		if abs(dchi) < 1e-9 then
			break
		end
	end

	local psi = chi * chi * alpha
	local c2, c3 = stumpff(psi)

	-- Lagrange f & g coefficients.
	local f = 1 - (chi * chi / r0) * c2
	local g = dt - (chi * chi * chi / sqrtmu) * c3
	local posNew = vadd(vscale(r0vec, f), vscale(v0vec, g))

	local rNew = vmag(posNew)
	if rNew < 1e-9 then
		rNew = 1e-9
	end
	local fdot = (sqrtmu / (rNew * r0)) * (alpha * chi * chi * chi * c3 - chi)
	local gdot = 1 - (chi * chi / rNew) * c2
	local velNew = vadd(vscale(r0vec, fdot), vscale(v0vec, gdot))

	return { position = posNew, velocity = velNew }
end

-- Orbital element readout. bodyRadius is optional: when supplied, periapsis,
-- apoapsis and altitude are reported as heights ABOVE the surface (KSP style);
-- when omitted they are distances from the body centre.
function Orbit.getReadout(state: State, mu: number, bodyRadius: number?): Readout
	local R = bodyRadius or 0
	local pos = state.position
	local vel = state.velocity

	local r = vmag(pos)
	local speed = vmag(vel)
	local energy = speed * speed * 0.5 - mu / r

	local sma
	if abs(energy) < 1e-12 then
		sma = huge
	else
		sma = -mu / (2 * energy)
	end

	-- Eccentricity vector: e = ((v^2 - mu/r) r - (r.v) v) / mu
	local rv = vdot(pos, vel)
	local coef = (speed * speed - mu / r)
	local ex = (coef * pos.x - rv * vel.x) / mu
	local ey = (coef * pos.y - rv * vel.y) / mu
	local ez = (coef * pos.z - rv * vel.z) / mu
	local ecc = sqrt(ex * ex + ey * ey + ez * ez)

	local periapsis, apoapsis, period
	if ecc < 1 and sma ~= huge and sma > 0 then
		periapsis = sma * (1 - ecc) - R
		apoapsis = sma * (1 + ecc) - R
		period = 2 * pi * sqrt((sma * sma * sma) / mu)
	else
		-- Parabolic / hyperbolic: no apoapsis, no period.
		periapsis = sma * (1 - ecc) - R
		apoapsis = huge
		period = huge
	end

	return {
		semiMajorAxis = sma,
		eccentricity = ecc,
		periapsis = periapsis,
		apoapsis = apoapsis,
		period = period,
		specificEnergy = energy,
		speed = speed,
		altitude = r - R,
	}
end

-- Speed required for a circular orbit at the given radius (distance from centre).
function Orbit.circularSpeed(radius: number, mu: number): number
	return sqrt(mu / radius)
end

-- Sample points along the orbit for drawing. For a closed orbit it walks one
-- full period (or `window` seconds if given). For an open orbit it samples a
-- symmetric time window centred on "now".
function Orbit.sampleOrbitPath(state: State, mu: number, samples: number, window: number?): { Vec3 }
	samples = samples or 120
	if samples < 2 then
		samples = 2
	end

	local readout = Orbit.getReadout(state, mu)
	local span
	local start = 0

	if window then
		span = window
		if readout.period == huge then
			start = -span * 0.5
		end
	elseif readout.period ~= huge then
		span = readout.period
	else
		span = 600
		start = -span * 0.5
	end

	local points = table.create(samples + 1)
	for i = 0, samples do
		local t = start + (i / samples) * span
		local s = Orbit.propagate(state, mu, t)
		points[i + 1] = s.position
	end
	return points
end

-- Render boundary: sim Vec3 -> render Vector3, offset by the floating origin.
function Orbit.toVector3(p: Vec3, originOffset: Vec3?): Vector3
	if originOffset then
		return Vector3.new(p.x - originOffset.x, p.y - originOffset.y, p.z - originOffset.z)
	end
	return Vector3.new(p.x, p.y, p.z)
end

-- Render boundary: render Vector3 -> sim Vec3, offset by the floating origin.
function Orbit.fromVector3(v3: Vector3, originOffset: Vec3?): Vec3
	if originOffset then
		return { x = v3.X + originOffset.x, y = v3.Y + originOffset.y, z = v3.Z + originOffset.z }
	end
	return { x = v3.X, y = v3.Y, z = v3.Z }
end

return Orbit
