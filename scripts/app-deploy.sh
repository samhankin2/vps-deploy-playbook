#!/bin/bash
#
# Deploy the app to the VPS: pull, restart, health check, roll back on failure.
#
# Installed as /usr/local/bin/<APP_NAME>-deploy and run as root by CI:
#   ssh -i deploy_key ubuntu@<host> "sudo /usr/local/bin/<APP_NAME>-deploy"
#
# Configure with environment variables (or edit the defaults):
#   APP_NAME     short app name
#   APP_DIR      code directory
#   SERVICE      systemd service name
#   HEALTH_URL   local health endpoint
#   BRANCH       git branch to deploy
#   COMMIT_FILE  where to record the deployed commit
#
set -euo pipefail

APP_NAME="${APP_NAME:-myapp}"
APP_DIR="${APP_DIR:-/opt/${APP_NAME}}"
SERVICE="${SERVICE:-${APP_NAME}}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:3000/api/health}"
BRANCH="${BRANCH:-main}"
COMMIT_FILE="${COMMIT_FILE:-/var/lib/${APP_NAME}/commit.txt}"

log() { echo "[deploy $(date -u '+%H:%M:%S')] $*"; }

cd "$APP_DIR"

PREV_SHA="$(git rev-parse HEAD)"
log "current commit: $PREV_SHA"

log "fetching origin/$BRANCH"
git fetch --quiet origin "$BRANCH"

# Compare COMMITS, not trees: after a revert that restores identical content a
# tree comparison would wrongly report "already up to date".
REMOTE_SHA="$(git rev-parse "origin/$BRANCH")"
if [ "$REMOTE_SHA" != "$PREV_SHA" ]; then
  log "updating to origin/$BRANCH ($REMOTE_SHA)"
  git checkout --quiet "$BRANCH"
  git merge --ff-only --quiet "origin/$BRANCH"
  NEW_SHA="$(git rev-parse HEAD)"
  log "deployed commit: $NEW_SHA"

  if ! git diff --quiet "$PREV_SHA" "$NEW_SHA" -- package.json; then
    log "package.json changed -> npm ci"
    npm ci --omit=dev --no-audit --no-fund
  fi

  # Keep the installed copy of this script in step with the repository, so the
  # box refreshes itself on every deploy.
  if [ -f "$APP_DIR/deploy/app-deploy.sh" ]; then
    install -m 0755 "$APP_DIR/deploy/app-deploy.sh" "/usr/local/bin/${APP_NAME}-deploy"
    log "refreshed /usr/local/bin/${APP_NAME}-deploy"
  fi
else
  log "already up to date, restarting anyway"
fi

rollback() {
  log "health check failed -> rolling back to $PREV_SHA"
  git reset --hard --quiet "$PREV_SHA"
  systemctl restart "$SERVICE" || true
  sleep 3
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "rollback succeeded, service is healthy on $PREV_SHA"
  else
    log "ROLLBACK FAILED - service is not healthy on $PREV_SHA"
  fi
  exit 1
}

log "restarting $SERVICE"

# Record what is deployed so the health endpoint can report it.
mkdir -p "$(dirname "$COMMIT_FILE")"
printf '%s\n' "$(git rev-parse HEAD)" > "$COMMIT_FILE"

systemctl restart "$SERVICE"

log "health checking"
for attempt in $(seq 1 15); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "healthy after ${attempt}s"
    log "done: $(curl -fsS "$HEALTH_URL")"
    exit 0
  fi
  sleep 1
done

rollback
