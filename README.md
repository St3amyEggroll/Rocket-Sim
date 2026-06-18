# RocketSim

A Kerbal-Space-Program-style game for Roblox (Luau), synced with Rojo. Build
rockets from parts, launch them, and fly real two-body orbital mechanics.

This repo is built in phases. **Phase 1 (this commit)** proves the whole flight
pipeline end to end with a single test sphere.

## Project layout (Rojo)

```
default.project.json
src/
  shared/                         -> ReplicatedStorage.Shared
    OrbitMechanics.lua            (the physics core - see note below)
    Config.lua                    (all tuning: body, craft, camera, units)
    Registry.lua                  (service locator so systems find each other)
    Signal.lua                    (lightweight synchronous event)
  server/
    init.server.lua               -> ServerScriptService.Server (Script)
  client/
    init.client.lua               -> StarterPlayer.StarterPlayerScripts.Client (LocalScript bootstrap)
    Systems/
      FloatingOriginController.lua
      InputController.lua
      FlightController.lua
      CraftRenderer.lua
      CameraController.lua
      HUDController.lua
```

Rojo naming: `*.server.lua` = Script, `*.client.lua` = LocalScript,
`*.lua` / `init.lua` = ModuleScript.

### Note on `OrbitMechanics.lua`

The brief said a validated physics core already existed and must not be
rewritten. The repository was empty, so this file was **created from scratch to
match the documented API exactly** (universal-variable Kepler propagation +
RK4). If you have your own validated module, drop it in at
`src/shared/OrbitMechanics.lua`; nothing else needs to change because every
other module only uses the public API.

## Architecture

- **Flight runs entirely client-side.** The server only sets up single-player
  feel now; persistence (ProfileStore) comes in a later phase.
- **The craft is kinematic.** Its position comes from `OrbitMechanics`, never
  from Roblox rigid-body physics, and it is moved with `PivotTo`.
- **Floating origin.** The craft is kept near render `(0,0,0)`; the rendered
  universe is offset by the craft's true sim position. Sim positions are
  double-precision `{x,y,z}` tables, converted to `Vector3` only at the render
  boundary (`Orbit.toVector3`).
- **On-rails vs powered.** Engine off -> `Orbit.propagate` (analytic, time-warp
  ready). Thrust on -> `Orbit.integrate` every frame.
- **Anti-tangle.** Each system is a module with `:Init()` then `:Start()`. The
  bootstrap runs all `Init` first, then all `Start`. Modules find each other at
  runtime via `Registry:Get("Name")`, never by requiring each other at the top.

## Run it

1. Install [Rojo](https://rojo.space/) (plugin + CLI).
2. From the repo root: `rojo serve`
3. In Roblox Studio, connect via the Rojo plugin.
4. Press **Play**.

## Phase 1 - what to test in Studio

You spawn already in a **low circular orbit** around `Terra`, engine off.

1. **Coasting works (propagate + floating origin + render + camera + HUD).**
   Watch the sphere coast in a clean circle around the planet. The HUD shows a
   near-zero eccentricity, a steady altitude, and a finite period (~80 s). Hold
   **RMB + drag** to orbit the camera; **wheel** to zoom out and see the whole
   orbit.
2. **Powered flight works (integrate).** Make sure thrust mode is **Prograde**
   (press `1`). Hold **Shift** to throttle up (HUD throttle climbs, status turns
   `POWERED`, green). Apoapsis rises as you burn.
3. **Reach a new stable circular orbit.** Cut the engine (`X`), coast up toward
   apoapsis (watch Altitude approach Apoapsis), then burn **Prograde** again
   until Periapsis rises to meet Apoapsis and eccentricity drops back near 0.
   Cut the engine: a new, higher, stable circular orbit.

Extra to try: press `2` (Retrograde) and burn to lower the orbit; burn enough
and Periapsis drops below the surface, you descend, and the craft "lands"
(status `LANDED`). Press `3` (RadialOut) + Shift to lift off again.

### Controls

| Input          | Action                                            |
| -------------- | ------------------------------------------------- |
| Shift / Ctrl   | Throttle up / down (hold)                         |
| Z / X          | Throttle full / cut                               |
| 1 2 3 4        | Thrust: Prograde / Retrograde / RadialOut / RadialIn |
| RMB + drag     | Orbit camera                                      |
| Mouse wheel    | Zoom                                              |

## Roadmap

- **Phase 2:** MapViewController (draw orbit via `sampleOrbitPath`) + time warp.
- **Phase 3:** VAB part builder + mass/staging/delta-v stats feeding thrust.
- **Phase 4:** second body, sphere-of-influence transitions, maneuver nodes.
- **Phase 5:** atmosphere/drag via the `extraAccel` hook, reentry, landing.
