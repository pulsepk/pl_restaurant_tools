# pl_restaurant_tools

In-game dev tools for building restaurant location data for Qbox restaurant scripts. Instead of hand-writing coordinates in `location.lua`, you place things in the world and the tool prints ready-to-paste Lua code to your F8 console and the server console.

## Tools

| Command | What it does |
|---|---|
| `/rtlocation` | Builds a full `Location.Management` entry + its `Stand` sub-table (interaction spot + where the player stands). |
| `/rtchair` | Builds a `Location.ChairGroups` entry — sit zone, per-chair sit/stand positions. |
| `/rttable` | Builds a `Location.Tables` entry with a footprint box for kitchen/dining tables. |
| `/rtprop` | Quickly grabs a `vec3`/`vec4` for placing a prop (spawns the real model so you can see it in place). |
| `/rtattach` | Tunes rpemotes-style `PropPlacement` offsets by attaching a prop live to your ped and nudging position/rotation. |

(The command prefix `rt` can be changed in `shared/config.lua`.)

## Usage

1. Run any command above in-game.
2. Follow the on-screen prompts/dialogs to fill in names, labels, etc.
3. Place points in the world:
   - Aim to move X/Y
   - Scroll to raise/lower Z
   - Q/E to rotate
   - ENTER to confirm, BACKSPACE to cancel/go back
4. When done, the generated Lua snippet is printed to your F8 console and the server console — copy it into the relevant restaurant's `location.lua` (or `AnimationList.lua` for `/rtattach`).

## Requirements

- Dependencies: `ox_lib`, `pl_lib`
- Access is gated by the ace permission `pl_restaurant.locationbuilder` — grant it to yourself/devs in `server.cfg`:
  ```
  add_ace group.admin pl_restaurant.locationbuilder allow
  ```
