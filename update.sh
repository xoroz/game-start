#!/usr/bin/env bash
# Cron: */10 * * * * /home/cbot/projects/star-drift/update.sh >> /home/cbot/logs/star-drift-deploy.log 2>&1
# Logic lives in ~/scripts/app-update.sh (docs: ~/CLAUDE.md "update.sh").
APP_DIR="$(cd "$(dirname "$0")" && pwd)" BRANCH=main SERVICES="star-drift" \
  BUILD="./build.sh" VERSION_CMD="git rev-parse --short HEAD" \
  HEALTH_URL=http://127.0.0.1:3840/api/scores exec "$HOME/scripts/app-update.sh"
