# Star Drift

A 1–2 player co-op arcade shooter made with [LÖVE](https://love2d.org/) 11.5. Pick one of five ships, shoot rocks and enemies that fire back, collect stars to clear levels, unlock four guns, and grab shields and extra lives. All graphics are drawn in code and all sound and music is synthesized at startup, so the game has no asset files.

It runs on desktop, on Linux retro handhelds through [PortMaster](https://portmaster.games/), and in a web browser through [love.js](https://github.com/Davidobot/love.js).

## Controls

| Action | Gamepad | Keyboard P1 | Keyboard P2 |
|---|---|---|---|
| Move | D-pad / left stick | WASD | Arrows |
| Fire (hold) | A, X or right trigger | Space / F | Right Ctrl / . |
| Aim + fire | Right stick | | |
| Dash | B or left trigger | Left Shift / G | / |
| Switch gun | L1 / R1 / Y | Q / E | , |
| Start / pause | Start | Enter | |
| Music on/off | Y while paused | M | |
| Back / quit | Select | Esc | |
| Fullscreen | | F11 | |

In 1-player mode every gamepad and both keyboard sets control P1. In 2-player mode each player presses A on the ship select screen to claim a gamepad (the first one becomes P1); keyboard sets stay fixed to P1 and P2.

Menus also follow the left stick. Gamepads that support it rumble on hits, kills, pickups, dashes and level-ups. If a player's gamepad is unplugged mid-game, the game pauses; reconnect it and press A to rejoin.

## Running on desktop

Install LÖVE 11.5, then:

```bash
love game
```

Set `STARDRIFT_HANDHELD=1` to try the handheld setup (fullscreen, no mouse, 1x render scale).

### Smoke tests

```bash
STARDRIFT_TEST=1 love game
STARDRIFT_TEST=select love game
STARDRIFT_TEST=scores love game
```

The first runs a muted 2-player game at level 7 for about 12 seconds. The second walks through the ship-select screen. The third ends a game, enters initials and shows the score table (it uses a separate `stardrift-test` save folder). Each prints a `TEST ...` line, saves a screenshot to the save folder (`~/.local/share/love/stardrift/` on Linux), and quits.

## Building

```bash
./build.sh
```

This produces:

- `dist/ports/` and `dist/stardrift.zip`: the PortMaster port. Copy the contents of `dist/ports/` into the `ports` folder on the handheld's SD card (often `/roms/ports/`).
- `dist/web/`: the browser version, built with love.js 11.4.1 through `npx`, so it needs Node.js and internet access the first time.

Run `./build.sh --no-web` to build only the port.

## High scores

When a game ends with points, players enter three initials (D-pad up/down changes the letter, left/right moves, A goes to the next letter, Start saves; on a keyboard just type and press Enter). The game-over screen then shows the top 5.

- **Desktop and handheld:** scores are saved on the device (`scores.txt` in the save folder).
- **Browser:** scores go to the shared online leaderboard on your server (`server/leaderboard.py`), so everyone sees the same "WORLD TOP 5". If the server can't be reached, the game shows the scores saved in that browser instead.

The page talks to the server through `web/leaderboard.js`, which `build.sh` adds to the web build. Lua can't make HTTP requests in love.js, so the game prints a request line, the script calls the API and writes the answer into the game's save folder, and the game reads it.

The leaderboard trusts what the browser sends, so a determined player could post a fake score. Delete bad rows with `sqlite3` (see below).

## Hosting the web version

The game is static files plus one small API process:

| Part | What | Needs |
|---|---|---|
| Game files | `dist/web/` (`index.html`, `love.js`, `love.wasm`, `game.js`, `game.data`, `leaderboard.js`, `theme/`) | Any static web server |
| Leaderboard API | `server/leaderboard.py` | Python 3.8+ (standard library only), stores scores in one SQLite file |

Server requirements:

1. **nginx** (or Caddy) to serve the files and forward `/stardrift/api/` to the API.
2. **HTTPS** (Let's Encrypt). Browsers limit audio and gamepads on insecure pages.
3. **`.wasm` served as `application/wasm`.** Recent nginx and Caddy already do this.
4. **Compression (recommended)** for `.wasm`, `.js` and `.data`.
5. **No special headers.** The build uses love.js compatibility mode (`-c`). Only if you remove `-c` from `build.sh` must the server also send `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`.

The API listens on `127.0.0.1:8787` only, so no firewall port needs opening.

### Deploying to apps.texngo.it

The server keeps its own clone of this repository in `/opt/stardrift`, builds the web version there, and `update.sh` redeploys automatically whenever `main` changes on GitHub. These steps serve the game at `https://apps.texngo.it/stardrift/`. Run them as root (or with `sudo`).

**1. Install what the build needs**

git, Node.js (for `npx love.js`), zip, rsync and Python 3.8+. On Debian/Ubuntu:

```bash
sudo apt install git nodejs npm zip rsync python3
```

On Fedora/RHEL:

```bash
sudo dnf install git nodejs npm zip rsync python3
```

**2. Clone the repository and do the first deploy**

```bash
sudo git clone https://github.com/xoroz/game-start.git /opt/stardrift
sudo SERVICE= /opt/stardrift/update.sh --force
```

This builds the game and copies it to `/var/www/apps.texngo.it/stardrift/`. `SERVICE=` skips the leaderboard restart, because the service isn't installed yet. To publish somewhere else, set `WEB_ROOT=/some/path` in front of `update.sh` (and in the cron line below).

**3. Install the leaderboard API as a service**

```bash
sudo cp /opt/stardrift/server/stardrift-leaderboard.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now stardrift-leaderboard
curl http://127.0.0.1:8787/api/scores
```

The last command should print `{"top": []}`. Scores are stored in `/var/lib/stardrift/leaderboard.sqlite3`. Back up that file to keep them; updates never touch it.

**4. Add the game to nginx**

Inside the `server { ... }` block for `apps.texngo.it`:

```nginx
location /stardrift/api/ {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header X-Real-IP $remote_addr;
}

location /stardrift/ {
    alias /var/www/apps.texngo.it/stardrift/;
    types { application/wasm wasm; }
    default_type application/octet-stream;
    gzip on;
    gzip_types application/wasm application/javascript application/octet-stream;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

If the site has no certificate yet:

```bash
sudo certbot --nginx -d apps.texngo.it
```

**5. Turn on automatic updates**

Open root's crontab:

```bash
sudo crontab -e
```

Add this line:

```
*/10 * * * * /opt/stardrift/update.sh >> /var/log/stardrift-update.log 2>&1
```

Every 10 minutes `update.sh` fetches `origin/main`. If there are new commits, it rebuilds, publishes the web build, and restarts the leaderboard only if `server/` changed. When nothing changed it does nothing and logs nothing. If the build fails, the live site stays on the previous version and the error is in `/var/log/stardrift-update.log`. Don't edit files in `/opt/stardrift` by hand: the update refuses to overwrite local changes and stops with an error.

**6. Check it**

```bash
curl https://apps.texngo.it/stardrift/api/scores
```

Then open https://apps.texngo.it/stardrift/ and play a game to the end.

**Removing a bad score:**

```bash
sudo sqlite3 /var/lib/stardrift/leaderboard.sqlite3 "DELETE FROM scores WHERE name = 'XXX';"
```

### Caddy instead of nginx

```caddyfile
apps.texngo.it {
    handle /stardrift/api/* {
        reverse_proxy 127.0.0.1:8787
    }
    handle_path /stardrift/* {
        root * /var/www/apps.texngo.it/stardrift
        encode gzip
        file_server
    }
}
```

Caddy gets the HTTPS certificate on its own.

### Testing locally

The leaderboard script can serve the web build itself:

```bash
python3 server/leaderboard.py --static dist/web --port 8001 --db dist/leaderboard-dev.sqlite3
```

Then open http://localhost:8001. Opening `index.html` straight from disk does not work. Click the page once if there is no sound; browsers block audio until the player interacts.

## License

See [LICENSE](LICENSE).
