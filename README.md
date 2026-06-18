# RocketSim

A Kerbal-Space-Program-style game for Roblox (Luau), synced with Rojo. Build
rockets from parts, launch them, and fly real two-body orbital mechanics.

Built in phases. **Phases 1-2 are in:** the full flight pipeline plus a map view
that draws the orbit and on-rails time warp.

## Project layout (Rojo)

```
default.project.json
src/
  shared/                         -> ReplicatedStorage.Shared
    OrbitMechanics.lua            (physics core - see note below)
    Config.lua                    (all tuning: body, craft, camera, warp, units)
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
      CrewController.lua           (rides the Roblox avatar on the craft)
      MapViewController.lua        (draws the orbit + apo/peri markers)
      CameraController.lua
      HUDController.lua
```

Rojo naming: `*.server.lua` = Script, `*.client.lua` = LocalScript,
`*.lua` / `init.lua` = ModuleScript.

### Note on `OrbitMechanics.lua`

The brief said a validated physics core already existed; the repo was empty, so
this file was **created from scratch to match the documented API exactly**
(universal-variable Kepler `propagate` + RK4 `integrate`). Drop your own
validated module in at `src/shared/OrbitMechanics.lua` and nothing else changes,
since every other module only uses the public API.

## Architecture

- **Flight runs entirely client-side.** The server enables the single-player
  avatar; persistence (ProfileStore) comes later.
- **The craft is kinematic.** Position comes from `OrbitMechanics`, never Roblox
  rigid-body physics, and is moved with `PivotTo`. The avatar is anchored and
  re-pivoted onto the craft each frame (`CrewController`).
- **Floating origin.** The craft is kept near render `(0,0,0)`; the rendered
  universe is offset by its true sim position. Sim positions are double-precision
  `{x,y,z}` tables, converted to `Vector3` only via `Orbit.toVector3`.
- **On-rails vs powered.** Engine off -> `Orbit.propagate` (analytic; dt is
  scaled by time warp). Thrust on -> `Orbit.integrate` every frame at real dt.
- **Anti-tangle.** Each system is a module with `:Init()` then `:Start()`. The
  bootstrap runs all `Init` first, then all `Start`. Modules find each other at
  runtime via `Registry:Get("Name")` and communicate through FlightController's
  per-frame `Updated` signal.

## Run it

1. Install [Rojo](https://rojo.space/) (this repo pins it via Rokit if you keep a
   `rokit.toml`; `rokit install` then `rojo serve`).
2. In Studio open a Baseplate, connect via the Rojo plugin, press **Play**.

## What to test in Studio

You spawn in a **circular orbit** around `Terra`, in **Map view**, so you can
immediately watch the craft travel around its orbit line.

1. **See it orbit (Phase 2 map + time warp).** Press `.` a few times to raise
   time warp (HUD shows `Warp`). The craft visibly tracks the blue orbit line;
   the red marker is apoapsis, green is periapsis. `,` lowers warp.
2. **Coast = stable orbit (propagate).** At any warp the line stays a clean
   circle (eccentricity ~0, steady altitude). **RMB+drag** to rotate the view,
   **wheel** to zoom the map.
3. **Burn = change orbit (integrate).** Press `M` to drop to **Flight** (chase)
   view and see your avatar on the craft. Make sure thrust mode is **Prograde**
   (`1`), hold **Shift** to throttle up. Switch back to Map (`M`) and watch the
   orbit line stretch as apoapsis rises. (Warp auto-resets to 1x while burning.)
4. **Reach a new circular orbit.** Cut the engine (`X`), warp to apoapsis, then
   burn **Prograde** until the periapsis marker rises to meet apoapsis and the
   line becomes a circle again.

Also try: `2` (Retrograde) to lower the orbit until it dips into the surface and
the craft `LANDED`s; `3` (RadialOut) + Shift to lift off again.

### Controls

| Input        | Action                                               |
| ------------ | ---------------------------------------------------- |
| Shift / Ctrl | Throttle up / down (hold)                            |
| Z / X        | Throttle full / cut                                  |
| 1 2 3 4      | Thrust: Prograde / Retrograde / RadialOut / RadialIn |
| . / ,        | Time warp up / down (engine off only)                |
| M            | Toggle Map / Flight view                             |
| RMB + drag   | Orbit camera                                         |
| Mouse wheel  | Zoom                                                 |

## Roadmap

- **Phase 3:** VAB part builder + mass/staging/delta-v stats feeding thrust.
- **Phase 4:** second body, sphere-of-influence transitions, maneuver nodes.
- **Phase 5:** atmosphere/drag via the `extraAccel` hook, reentry, landing.
