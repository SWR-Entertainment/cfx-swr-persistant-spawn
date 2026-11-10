# cfx-swr-persistant-spawn

Persistent spawn resource for FiveM using a local SQLite3 file.

## What it does

- On first spawn after joining, client asks server for spawn location.
- Server checks SQLite table for player's last saved coordinates.
- If found, player is moved there.
- If not found, player is moved to `defaultSpawn` from `config.json`.
- Position is saved periodically and on player drop.

## Files

- `fxmanifest.lua`
- `config.json`
- `server/main.js`
- `client/main.lua`
- `package.json`

## Setup

1. Open this resource folder in a terminal.
2. Install dependency:

   ```bash
   npm install
   ```

3. Add to your `server.cfg`:

   ```cfg
   ensure cfx-swr-persistant-spawn
   ```

4. Restart the server/resource.

## Config

Edit `config.json`:

- `dbFileName`: SQLite database file created in this resource folder.
- `defaultSpawn`: Used when a player has no saved location.
- `autoSaveIntervalMs`: How often client sends position updates.
- `skyDrop.enabled`: GTA Online style drop-in from the sky on join. `false` = plain fade teleport.
- `skyDrop.loadingScreenResource`: Loading screen resource to hand off with (default `cfx-swr-loadingscreen`).
- `skyDrop.skyHoldMs`: How long the sky camera holds before the drop starts.
- `skyDrop.switchOutFlags`: Flags for the hidden ascent. `16384` suppresses its whoosh/flash so it can't be heard through the loading screen; `0` = stock.
- `skyDrop.collisionTimeoutMs`: Max wait for the world to stream in at the spawn before dropping anyway.

## Sky drop / loading screen handoff

On join the loading screen stays up until this resource is ready:

1. `playerSpawned` → spawn requested from the server (bar: "Finding your spot...").
2. Ped is moved to the saved spot and collisions load (bar: "Loading your area...").
3. `SwitchOutPlayer` pulls the camera into the sky, still hidden by the loading screen.
4. `cfx-swr-loadingscreen:release` → the bar hits 100% and the loading screen closes on the sky shot.
5. After `skyHoldMs`, `SwitchInPlayer` drops the camera down to the player.

Client events used between the two resources:

- `cfx-swr-loadingscreen:progress (fraction, label)`: drives the final part of the loading bar.
- `cfx-swr-loadingscreen:release`: tells the loading screen to finish and close.
- `cfx-swr-loadingscreen:closed`: fired by the loading screen once the NUI is gone.

If the server doesn't answer within 15s the loading screen is released anyway. The loading screen also
closes on its own after 45s. Positions aren't saved until the player has landed, so a slow load
can't overwrite the saved spot.

## Commands

- `/setspawn`: Saves your current location as your persistent spawn point.

## Notes

- SQLite file is local to your server machine.
- Primary identifier preference: `license:` → `fivem:` → `discord:` → `steam:`.
