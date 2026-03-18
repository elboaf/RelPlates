# RelPlates

A nameplate addon for WoW 1.12.1 (Turtle WoW). RelPlates is a minimal implementation and complete rewrite of GudaPlates, built from the ground up with a fully standalone threat engine, role-aware color system, and clean architecture designed around the SuperWoW API.

---

## Requirements

- **SuperWoW** — required. RelPlates uses SuperWoW's GUID-based unit APIs throughout.
- **Nampower** — optional. Enables direct memory reads for mana and class data without targeting.
- **UnitXP SP3** — optional. Detected at load; reserved for future use.
- **TWThreat** — not required. RelPlates has its own built-in threat engine that speaks the same wire protocol.

---

## Features

### Nameplate Layout
- Health bar with configurable dimensions, text format, and font size
- Optional mana bar below the health bar (shown only for mana-using units)
- Cast bar below the health/mana stack with spell name, countdown timer, and spell icon
- Name and level text above the health bar
- Raid icons reparented and repositioned to either side of the health bar
- Target brackets that hug the full plate (health + mana) on the currently targeted unit, with GUID-based exact matching so same-name mobs are never confused

### Threat Colors
RelPlates includes a fully standalone AoE threat implementation. It speaks the same TWThreat wire protocol (`TWT_UDTSv4_TM`) and maintains its own threat tables independently — TWThreat does not need to be installed.

Threat coloring is **role-aware**:

**Tank mode**
- Mob you have aggro on: **red → orange** gradient as the highest challenger climbs past 50% of your threat. Full orange = about to lose it.
- Mob you've lost aggro on: static **blue**.

**DPS / Healer mode**
- Mob you don't have aggro on: **blue → red** gradient as your threat climbs past 50% of the tank's. Full red = about to pull.
- Mob you have aggro on: static **red**.

The gradient floor at 50% means low-threat noise is suppressed — colors only start shifting when the situation is actually developing. An aggro transition always produces a sharp color snap, making threshold crossings immediately visible even in crowded AoE pulls.

**Data sources, in priority order:**
1. **TMTv1= (tank mode packets)** — per-creature multi-mob threat data. Received when you have top threat on at least one mob in a group fight. Expires after 3 seconds of no new packets, at which point the system falls through to single-target data automatically.
2. **TWTv4= (single-target packets)** — per-player threat on your current target. Polled every 0.2 seconds while targeting an elite or worldboss in a group. Provides gradient coloring for the targeted mob even after tank mode packets stop (e.g. last mob standing).
3. **Binary fallback** — when no threat data is available, mobs attacking you show red and all others show blue.

**AoE threat limitations:** The Turtle WoW threat API only sends tank mode data when the requesting player has top threat on at least one mob. This means DPS and healers receive single-target data for their current target but not gradient colors for other mobs in AoE scenarios. This is an API-level restriction and not something RelPlates can work around.

### Color Customization
All threat colors are fully configurable via the settings window:
- Tank aggro color (red endpoint)
- Tank warning color (orange endpoint)
- DPS safe color (blue endpoint)
- Other tank color
- Tapped color
- Mana bar color
- Target border color

Each color can be set via a **color picker** or typed directly as a **hex value** (e.g. `D63333`).

### Off-Tank List
RelPlates supports a manual off-tank list for multi-tank scenarios. Mobs targeting a listed off-tank show a distinct light-red color rather than the standard threat gradient. The list is managed via:
- `/rp tanks` — opens the off-tank list GUI
- `/rp ot` — toggles your current target in/out of the list
- `/rp ot add <name>` / `/rp ot remove <name>` — manage by name
- `/rp ot list` / `/rp ot clear`

### Settings Window
Opened via `/rp config`, right-clicking the minimap button, or Ctrl+clicking it.

**General tab** — role selection (Tank / DPS), overlap mode toggle, reset to defaults.

**Health tab** — bar width, bar height, health text visibility, mana bar height.

**Cast Bar tab** — cast icon visibility, independent width mode, cast bar height and width.

**Colors tab** — color swatches with hex input and color picker for all configurable colors.

### Minimap Button
Draggable minimap button. Left-drag to reposition. Right-click to open settings.

---

## Slash Commands

| Command | Description |
|---|---|
| `/rp` or `/relplates` | Show command list and current role |
| `/rp tank` | Set role to Tank |
| `/rp dps` | Set role to DPS/Healer |
| `/rp toggle` | Toggle between Tank and DPS |
| `/rp config` | Open settings window |
| `/rp tanks` | Open off-tank list GUI |
| `/rp ot` | Toggle current target in off-tank list |
| `/rp debugpacket` | Toggle debug logging (flushes to file after each combat) |
| `/rp debugthreat` | Print current threat data for target to chat |

---

## Debug Logging

`/rp debugpacket` enables detailed per-combat logging. The log flushes to `WoW/Interface/AddOns/RelPlates/imports/RelPlates_debug_<PlayerName>.txt` at the end of each combat, with separate files per character so two clients can be debugged simultaneously.

Each log captures:
- Raw TWTv4= and TMTv1= threat packets
- Parsed threat data arrivals (ST_DATA, TM_DATA)
- Target change events with current threat state
- Per-plate color state (name, key, color branch, threat %, data source) once per second per visible hostile plate
- Enemy cast events for mobs with nameplates
- Combat session start/end headers

---

## Credits

Based on [GudaPlates](https://github.com/gudaplatez) by Guda. Fully rewritten with SuperWoW-native APIs, a standalone threat engine, and role-aware coloring.
