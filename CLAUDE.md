# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Star Drift — a 1–2 player co-op arcade shooter written in Lua for **LÖVE 11.5**, packaged as a **PortMaster** port for Linux retro handhelds. No external assets: all graphics are drawn with primitives and all audio is synthesized at startup.

## Commands

```bash
love game                          # run on desktop (window maximized)
STARDRIFT_HANDHELD=1 love game     # simulate handheld: fullscreen, hidden mouse, 1x render scale
STARDRIFT_TEST=1 love game         # automated smoke test: 2 players, muted, jumps to level 7, spawns every enemy, saves screenshot.png, prints "TEST state=..." line, quits after ~12s
STARDRIFT_TEST=select love game    # drives ship-select screen (incl. taken-ship refusal), saves select.png, prints result, quits
STARDRIFT_TEST=scores love game    # forces game over, enters initials, saves scores.png; uses save identity "stardrift-test"
STARDRIFT_TEST=boss love game      # boss 1 vs bomb + missile, saves boss.png, kills it, checks next level starts
./build.sh                         # assemble dist/ports/ + dist/stardrift.zip, then browser build in dist/web/ (via npx love.js)
./build.sh --no-web                # port only
python3 server/leaderboard.py --static dist/web --port 8001 --db dist/leaderboard-dev.sqlite3   # web build + leaderboard API locally (file:// does not work)
```

Test screenshots and `best.txt` land in LÖVE's save dir for identity `stardrift` (on Linux: `~/.local/share/love/stardrift/`). There is no linter or unit-test suite; the `STARDRIFT_TEST` modes are the regression check.

## Layout

- `game/` — the LÖVE source (`main.lua`, `audio.lua`, `scores.lua`, `conf.lua`). This is the only place to edit game code.
- `web/leaderboard.js` — injected into the love.js `index.html` by `build.sh` (before `game.js`).
- `server/` — leaderboard API (`leaderboard.py`, Python stdlib + SQLite) and its systemd unit. Deploy steps in README.md.
- `update.sh` — server-side auto-deploy (root cron every 10 min in a clone at `/opt/stardrift`): ff-merges `origin/main`, runs `build.sh`, rsyncs `dist/web/` to `WEB_ROOT`, restarts `stardrift-leaderboard` only if `server/` changed. Anything pushed to `main` goes live within 10 minutes.
- `port/` — PortMaster metadata and launcher (`Star Drift.sh`, `port.json`, `gameinfo.xml`, optional `screenshot.png`). The launcher sets `STARDRIFT_HANDHELD=1` and redirects `XDG_DATA_HOME` so saves stay inside the port folder.
- `dist/` — build output, regenerated (`rm -rf`) by `build.sh`; gitignored, never edit by hand.
- The game description is duplicated in `port/port.json` (`desc`) and `port/gameinfo.xml` — update both when features change.

## Architecture (`game/main.lua`)

Single file, sectioned by `----- name` comment banners, all module-local state (no globals except LÖVE callbacks and `action`).

- **Fixed logical resolution 640×480.** Everything renders to one canvas, then is letterbox-scaled to the window. The canvas uses `dpiscale = k` (k = ceil(scale), forced to 1 on handheld) so shapes and fonts stay sharp; `resize()` recreates canvas and fonts when k changes. Always draw in 640×480 coordinates (`W`, `H`).
- **State machine:** `state` ∈ `title | select | play | pause | entry | over` (`entry` = typing initials; `gameOver()` picks entry or over). `love.update` only runs `updatePlay` in `play`; `drawWorld` + `drawOverlay` branch on state.
- **Input funnels into `action(a, id)`**: keyboard (`love.keypressed` via `GLOBAL_KEYS`/`MENU_KEYS`/per-player `KEYS` sets) and gamepad (`PAD_ACTIONS`) both translate to abstract actions (`start`, `back`, `confirm`, `dash`, `prev`, `next`, `left`, …) with a player id. Continuous input (movement, held fire) is polled separately in `axis()` / `fireHeld()`. In 1-player mode all key sets and all gamepads drive P1 (`keysetsFor`/`padsFor`). In 2-player mode pads are claimed, not indexed: `padPlayer(j)` assigns an unowned pad to the first free slot on its first press (`padOwner`/`playerPad`, reset when entering ship select); `love.joystickremoved` frees the slot and pauses. Right stick aims+fires (`aimAxis`), triggers fire/dash (`padAxis`), left stick drives menus (`stickMenus`, repeats while held). Vibration goes through `rumble(p, strength, dur)`. `STARDRIFT_TEST` modes ignore real gamepads.
- **Difficulty:** `diff` (one of `DIFFICULTIES`) scales lives/bombs, enemy shot speed + fire delay, spawn delay, rock speed, boss HP and drop chance. Best score, local score file and online table are all per difficulty (`diff.key`).
- **Boss stages:** `levelComplete()` on a level divisible by 3 calls `startBoss()` instead of `startLevel`; `boss` is non-nil during the fight (stars and spawns are off, HUD bar shows boss HP). `hitBoss` handles damage/defeat; after the death animation `updateBoss` calls `startLevel(level + 1)`.
- **Items:** pickups `life`/`shield`/`missile`/`bomb` (`PICKUP_COLORS`), planned per level in `startLevel` plus random enemy drops (`dropItem`). Missiles/bombs are stored on the player (`p.missiles`, `p.bombs`) and used with actions `missile`/`bomb` (`fireMissile`, `superBomb`). `startLevel` keeps pickups so boss drops survive the level change.
- **Data-driven content tables:** `GUNS` (gun k unlocks on level k), `ENEMIES` + `ENEMY_ORDER` (`lvl` = first level it appears), `SHIPS` (polygon art, nose along +x, fill polygons must be convex — concave shapes need `love.math.triangulate` like `starTris`), `LEVEL_NEWS` (banner text). Add content by extending these tables plus the matching `updateEnemy`/`drawEnemy` branch.
- **Level flow:** collecting `starsNeeded()` stars calls `levelComplete()` → `startLevel(n+1)`, which clears entities, sets the banner (no spawns while `banner > 0`), revives downed co-op partners with 1 life, and schedules one-shot pickups via `pickupPlan`. Difficulty scales from `level` and `numPlayers` inline in spawn timers.
- **Game over can happen mid-update:** `damagePlayer` may call `gameOver()`, which leaves `play`; update loops check `if state ~= "play" then return end` after anything that can damage a player — preserve this when adding new damage sources.
- Entity lists are iterated backwards with `table.remove` for deletion.

## Audio (`game/audio.lua`)

All SFX and the music loop are rendered into `SoundData` at `Audio.load()` (22050 Hz mono) via helpers `sweep`, `boom`, `arp`. Each sound has a pool of cloned sources so overlaps don't cut off. Call `Audio.play(name, pitchVariance)`; unknown names are silently ignored. Adding a sound = one `add(...)` line in `Audio.load`.

## Web build

`build.sh` zips `game/` into `dist/stardrift.love` and runs love.js 11.4.1 in compatibility mode (`-c`, no threads, so no COOP/COEP headers needed). love.js runs LÖVE **11.4**, so the build patches the web copy of `conf.lua` to `t.version = "11.4"` — avoid 11.5-only APIs. In game code, `WEB` (`love.system.getOS() == "Web"`) gates browser-specific behavior (no window maximize, no quit from title). love.js's `love.filesystem.read` raises on a missing file (desktop returns nil), so check `getInfo` first. Hosting requirements are in README.md.

## High scores (`game/scores.lua`)

Always stores scores locally (`scores.txt`). On web it also talks to the leaderboard API through a JS bridge, because Lua in love.js has no HTTP: Lua `print`s `STARDRIFT_API|<save dir>|top|<difficulty>` or `...|submit|ABC|score|level|<difficulty>`; `web/leaderboard.js` hooks `Module.print`, calls `api/scores` (relative URL), and writes the answer to `<save dir>/leaderboard.txt` via `Module.FS_createDataFile`; `Scores.update` polls that file (8 s timeout → `offline`, falls back to local list). Keep the line formats in both files in sync.

## Handheld constraints

Target devices are low-power ARM handhelds: `conf.lua` disables `physics` and `video` modules, render scale is held at 1x when `HANDHELD`, and controls must remain fully usable from a gamepad (keyboard is secondary).
