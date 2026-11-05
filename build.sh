#!/bin/bash
# Assemble the PortMaster port into dist/ and zip it.
# Copy the contents of dist/ports/ onto the SD card's ports folder (often /roms/ports/).
set -euo pipefail
cd "$(dirname "$0")"

rm -rf dist
mkdir -p dist/ports/stardrift/gamedata

cp game/*.lua dist/ports/stardrift/gamedata/
cp "port/Star Drift.sh" dist/ports/
chmod +x "dist/ports/Star Drift.sh"
cp port/port.json port/gameinfo.xml dist/ports/stardrift/
[ -f port/screenshot.png ] && cp port/screenshot.png dist/ports/stardrift/

(cd dist/ports && zip -qr ../stardrift.zip "Star Drift.sh" stardrift)
echo "Built dist/ports/ and dist/stardrift.zip"
