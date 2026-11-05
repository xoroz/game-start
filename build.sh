#!/bin/bash
# Assemble the PortMaster port into dist/ and zip it, then build the browser version into dist/web/.
# Copy the contents of dist/ports/ onto the SD card's ports folder (often /roms/ports/).
# Upload the contents of dist/web/ to any static web server (see README.md for the headers it needs).
set -euo pipefail
cd "$(dirname "$0")"

LOVEJS_VERSION=11.4.1   # newest love.js; runs LÖVE 11.4, which this game is compatible with

rm -rf dist
mkdir -p dist/ports/stardrift/gamedata

cp game/*.lua dist/ports/stardrift/gamedata/
cp "port/Star Drift.sh" dist/ports/
chmod +x "dist/ports/Star Drift.sh"
cp port/port.json port/gameinfo.xml dist/ports/stardrift/
[ -f port/screenshot.png ] && cp port/screenshot.png dist/ports/stardrift/

(cd dist/ports && zip -qr ../stardrift.zip "Star Drift.sh" stardrift)
echo "Built dist/ports/ and dist/stardrift.zip"

# Browser build. love.js 11.4 shows a version warning for a game asking for 11.5, so the web copy asks for 11.4.
if [ "${1:-}" = "--no-web" ]; then exit 0; fi
if ! command -v npx >/dev/null; then
  echo "npx not found: skipping web build (install Node.js to build dist/web/)"
  exit 0
fi
mkdir -p dist/web-src
cp game/*.lua dist/web-src/
sed -i 's/t.version = "11.5"/t.version = "11.4"/' dist/web-src/conf.lua
(cd dist/web-src && zip -q -9 -r ../stardrift.love .)
# -c = compatibility mode: no threads, so the server needs no COOP/COEP headers
npx --yes "love.js@$LOVEJS_VERSION" -c -t "Star Drift" -m 67108864 dist/stardrift.love dist/web
rm -rf dist/web-src
# leaderboard bridge must load before game.js so it can hook Module.print
cp web/leaderboard.js dist/web/
sed -i 's|<script type="text/javascript" src="game.js"></script>|<script type="text/javascript" src="leaderboard.js"></script>\n    &|' dist/web/index.html
grep -q 'src="leaderboard.js"' dist/web/index.html || { echo "failed to inject leaderboard.js into index.html"; exit 1; }
echo "Built dist/web/ (serve over HTTP; opening index.html from disk does not work)"
