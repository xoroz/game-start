#!/bin/bash
# Auto-deploy for the web server: pull origin/main, and when it moved, rebuild the web version,
# publish it to WEB_ROOT and restart the leaderboard if server/ changed.
# Run as root from a clone in /opt/stardrift, via cron every 10 minutes:
#   */10 * * * * /opt/stardrift/update.sh >> /var/log/stardrift-update.log 2>&1
# Prints nothing when there is nothing new. ./update.sh --force deploys even if nothing changed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"   # cron starts with a bare PATH; build.sh needs npx and zip

BRANCH=${BRANCH:-main}
WEB_ROOT=${WEB_ROOT:-/var/www/apps.texngo.it/stardrift}
SERVICE=${SERVICE-stardrift-leaderboard}   # set SERVICE= to skip the restart
STAMP=.deployed-commit                     # last commit published (gitignored)

log() { echo "$(date '+%F %T') $*"; }

# a slow build must not overlap with the next cron run
exec 9>.update.lock
flock -n 9 || { log "another update is still running"; exit 0; }

git fetch -q origin "$BRANCH"
git checkout -q "$BRANCH"
# fails loudly instead of overwriting if files were edited on the server
git merge -q --ff-only "origin/$BRANCH"

new=$(git rev-parse HEAD)
old=$(cat "$STAMP" 2>/dev/null || true)
if [ "$new" = "$old" ] && [ "${1:-}" != "--force" ]; then exit 0; fi

log "deploying $(git log -1 --format='%h %s') (was ${old:0:7})"
./build.sh
mkdir -p "$WEB_ROOT"
rsync -a --delete dist/web/ "$WEB_ROOT/"
log "published dist/web/ to $WEB_ROOT"

# restart the API only when its code changed (or when the previous state is unknown)
if [ -n "$SERVICE" ]; then
  if [ -z "$old" ] || ! git cat-file -e "$old^{commit}" 2>/dev/null || ! git diff --quiet "$old" "$new" -- server/; then
    systemctl restart "$SERVICE"
    log "restarted $SERVICE"
  fi
fi

echo "$new" > "$STAMP"
log "done"
