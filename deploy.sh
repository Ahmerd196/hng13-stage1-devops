#!/bin/sh
# POSIX-compatible deploy.sh
# Usage: ./deploy.sh
# Prompts user for inputs; supports --cleanup flag.
# Exit codes:
#  0 success
#  10 input error
#  20 ssh/connectivity error
#  30 remote install/deploy error
#  40 validation/test failure

# Basic safety
umask 0077

# Timestamp/log
NOW="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${NOW}.log"
touch "$LOGFILE" || { echo "Failed to create log file"; exit 1; }

log() {
	  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"
  }
err() {
	  printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2
  }

# Trap for unexpected exit
cleanup_local() {
	  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  }
trap 'err "Unexpected failure. Cleaning."; cleanup_local; exit 1' INT TERM HUP

log "Starting deploy script."

# Handle --cleanup quick path
if [ "${1-}" = "--cleanup" ]; then
	  log "Running cleanup mode."
	    read -r -p "Remote username: " REM_USER
	      read -r -p "Remote host (IP or domain): " REM_HOST
	        read -r -p "SSH key path (full): " SSH_KEY
		  read -r -p "Application container name (used during deploy): " CONTAINER_NAME
		    if [ -z "$REM_USER" ] || [ -z "$REM_HOST" ] || [ -z "$SSH_KEY" ] || [ -z "$CONTAINER_NAME" ]; then
			        err "Missing input for cleanup."
				    exit 10
				      fi
				        log "Stopping and removing container $CONTAINER_NAME on $REM_HOST"
					  ssh -o BatchMode=yes -i "$SSH_KEY" "$REM_USER@$REM_HOST" "sudo docker rm -f $CONTAINER_NAME 2>/dev/null || true; sudo rm -f /etc/nginx/sites-enabled/${CONTAINER_NAME}.conf /etc/nginx/sites-available/${CONTAINER_NAME}.conf; sudo systemctl reload nginx 2>/dev/null || true" \
						      && log "Cleanup commands executed." || err "Cleanup failed."
					    exit 0
fi

# Prompt & validate inputs
read -r -p "Git repo URL (https://github.com/owner/repo.git): " REPO_URL
if [ -z "$REPO_URL" ]; then err "Repo URL required"; exit 10; fi

# Get PAT securely (will not be echoed)
printf "Enter GitHub Personal Access Token (PAT) (input hidden): "
# POSIX sh doesn't reliably support stty -echo on all systems, but attempt:
if command -v stty >/dev/null 2>&1; then
	  stty -echo
	    read -r GIT_PAT
	      stty echo
	        printf "\n"
	else
		  read -r GIT_PAT
fi
if [ -z "$GIT_PAT" ]; then err "PAT required"; exit 10; fi

read -r -p "Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -r -p "Remote SSH username (e.g. ubuntu or root): " REM_USER
read -r -p "Remote host/IP: " REM_HOST
read -r -p "SSH private key path (full, e.g. /home/me/.ssh/id_rsa): " SSH_KEY
if [ ! -f "$SSH_KEY" ]; then err "SSH key not found at $SSH_KEY"; exit 10; fi

read -r -p "Container internal port (the port your app listens to inside the container): " APP_PORT
if [ -z "$APP_PORT" ]; then err "Application port required"; exit 10; fi

# Derive repo name and container name
REPO_NAME="$(basename "$REPO_URL" .git)"
CONTAINER_NAME="deploy_${REPO_NAME}"

log "Inputs received: repo=$REPO_URL branch=$BRANCH host=$REM_HOST user=$REM_USER repo_name=$REPO_NAME container=$CONTAINER_NAME app_port=$APP_PORT"

# Prepare local workspace
TMP_DIR="$(mktemp -d "/tmp/deploy_${REPO_NAME}_XXXX")" || { err "Failed to create temp dir"; exit 1; }
log "Created tmp dir $TMP_DIR"

# Clone or update the repo using PAT but avoid logging the PAT
# We create a safe URL for clone: https://<PAT>@github.com/owner/repo.git
SAFE_CLONE_URL="$(printf "%s" "$REPO_URL" | sed 's#https://##')"
CLONE_URL="https://${GIT_PAT}@${SAFE_CLONE_URL}"

log "Cloning repository (branch: $BRANCH) into $TMP_DIR"
cd "$TMP_DIR" || { err "cd failed"; exit 1; }
if [ -d "$REPO_NAME" ]; then
	  log "Repo already exists locally; pulling latest changes."
	    cd "$REPO_NAME" || exit 1
	      # Avoid exposing PAT in logs
	        GIT_ASKPASS=$(mktemp)
		  printf '#!/bin/sh\necho "$GIT_PAT"\n' > "$GIT_ASKPASS"
		    chmod +x "$GIT_ASKPASS"
		      export GIT_ASKPASS
		        git fetch origin "$BRANCH" >> "$LOGFILE" 2>&1 || { err "git fetch failed"; rm -f "$GIT_ASKPASS"; exit 1; }
			  git checkout "$BRANCH" >> "$LOGFILE" 2>&1 || { err "git checkout failed"; rm -f "$GIT_ASKPASS"; exit 1; }
			    git pull origin "$BRANCH" >> "$LOGFILE" 2>&1 || { err "git pull failed"; rm -f "$GIT_ASKPASS"; exit 1; }
			      rm -f "$GIT_ASKPASS"
		      else
			        # New clone
				  # Use -q to reduce console noise; still captured in logfile for troubleshooting if needed.
				    git clone --branch "$BRANCH" --single-branch "$CLONE_URL" "$REPO_NAME" >> "$LOGFILE" 2>&1 || { err "git clone failed (check PAT and repo URL)"; exit 1; }
				      cd "$REPO_NAME" || exit 1
fi
log "Repository ready at $PWD"

# Verify Dockerfile or docker-compose.yml exists
HAS_DOCKERFILE=0
HAS_DOCKER_COMPOSE=0
[ -f Dockerfile ] && HAS_DOCKERFILE=1
[ -f docker-compose.yml ] && HAS_DOCKER_COMPOSE=1

if [ "$HAS_DOCKERFILE" -eq 0 ] && [ "$HAS_DOCKER_COMPOSE" -eq 0 ]; then
	  err "Neither Dockerfile nor docker-compose.yml found in repo root. Please ensure one exists."
	    exit 10
fi
log "Dockerfile: $HAS_DOCKERFILE docker-compose.yml: $HAS_DOCKER_COMPOSE"

# Check SSH connectivity
log "Testing SSH connectivity to $REM_USER@$REM_HOST"
ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$SSH_KEY" "$REM_USER@$REM_HOST" "echo SSH_OK" >> "$LOGFILE" 2>&1 || { err "SSH connectivity test failed. Check network/security group/username/key"; exit 20; }
log "SSH connectivity OK"

# Build remote script to run on server (install docker, docker-compose-plugin, nginx, user to docker group)
REMOTE_SCRIPT="/tmp/deploy_remote_${REPO_NAME}.sh"
cat > "$TMP_DIR/deploy_remote.sh" <<'REMOTE_EOF'
#!/bin/sh
set -eu

LOG_REMOTE="/tmp/deploy_remote.log"
echo "$(date) remote deploy script started" > "$LOG_REMOTE"

# Update packages
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >> "$LOG_REMOTE" 2>&1
  sudo apt-get install -y ca-certificates curl gnupg lsb-release >> "$LOG_REMOTE" 2>&1
fi

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker..." >> "$LOG_REMOTE"
  curl -fsSL https://get.docker.com | sh >> "$LOG_REMOTE" 2>&1 || exit 1
fi

# Ensure docker group exists and add ubuntu user (if not root)
if ! getent group docker >/dev/null 2>&1; then
  sudo groupadd docker || true
fi
# Add user to docker group (safe even if already in)
sudo usermod -aG docker "$SUDO_USER" >/dev/null 2>&1 || true

# Install docker-compose plugin or docker-compose (prefers plugin)
if ! docker compose version >/dev/null 2>&1; then
  # Try apt install docker-compose-plugin
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin >> "$LOG_REMOTE" 2>&1 || true
  fi
  # fallback: download docker-compose (v2) binary
  if ! docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_PLUGIN=/usr/libexec/docker/cli-plugins/docker-compose
    sudo mkdir -p "$(dirname "$DOCKER_COMPOSE_PLUGIN")" || true
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o "$DOCKER_COMPOSE_PLUGIN" >> "$LOG_REMOTE" 2>&1 || true
    sudo chmod +x "$DOCKER_COMPOSE_PLUGIN" || true
  fi
fi

# Install nginx if missing
if ! command -v nginx >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y nginx >> "$LOG_REMOTE" 2>&1 || exit 1
    sudo systemctl enable --now nginx >> "$LOG_REMOTE" 2>&1 || true
  fi
fi

# Ensure docker is up
sudo systemctl enable --now docker 2>/dev/null || true
echo "$(date) remote setup finished" >> "$LOG_REMOTE"
REMOTE_EOF

# Upload and run remote script
log "Uploading remote setup script to $REM_HOST"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$TMP_DIR/deploy_remote.sh" "$REM_USER@$REM_HOST:/tmp/deploy_remote.sh" >> "$LOGFILE" 2>&1 || { err "Failed to upload remote script"; exit 20; }

log "Executing remote setup script"
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REM_USER@$REM_HOST" "sh /tmp/deploy_remote.sh" >> "$LOGFILE" 2>&1 || { err "Remote setup script failed"; exit 30; }
log "Remote environment prepared"

# Rsync project to remote (exclude .git)
log "Syncing project to remote host (this may take a while)..."
rsync -az --delete --exclude '.git' -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" "$PWD"/ "$REM_USER@$REM_HOST:/home/$REM_USER/${REPO_NAME}/" >> "$LOGFILE" 2>&1 || { err "Rsync failed"; exit 30; }
log "Files synced to /home/$REM_USER/${REPO_NAME}/ on remote."

# Remote deploy commands: build/run (compose preferred)
DO_DEPLOY_CMDS=$(cat <<EOF
set -eu
REPO_DIR="/home/$REM_USER/${REPO_NAME}"
cd "\$REPO_DIR"
# stop and remove any existing container or compose stack
# Compose v2 uses 'docker compose'
if [ -f docker-compose.yml ]; then
  echo "Stopping existing compose (if any)" >/tmp/deploy_stage.log 2>&1 || true
  sudo docker compose down --remove-orphans || true
  sudo docker compose pull || true
  sudo docker compose up -d --build
else
  # Identify image name
  IMG_NAME="${CONTAINER_NAME}_image"
  # Stop existing container
  sudo docker rm -f ${CONTAINER_NAME} 2>/dev/null || true
  # Build
  sudo docker build -t "\$IMG_NAME" .
  # Run (map host ephemeral port equal to APP_PORT)
  sudo docker run -d --name ${CONTAINER_NAME} -p 127.0.0.1:${APP_PORT}:${APP_PORT} "\$IMG_NAME"
  fi

# Health check: ensure container is running
sleep 3
if sudo docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" --format '{{.Names}}' | grep -q "${CONTAINER_NAME}"; then
  echo "Container ${CONTAINER_NAME} running" >> /tmp/deploy_stage.log
else
  echo "Container ${CONTAINER_NAME} not running!" >> /tmp/deploy_stage.log
  exit 1
fi

# Create simple nginx site config to proxy to container
NGCONF="/etc/nginx/sites-available/${CONTAINER_NAME}.conf"
cat <<NGEOF | sudo tee "\$NGCONF" >/dev/null
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGEOF

sudo ln -sf "\$NGCONF" /etc/nginx/sites-enabled/${CONTAINER_NAME}.conf
sudo nginx -t
sudo systemctl reload nginx

# Quick curl test on remote
sleep 1
curl -I http://127.0.0.1:${APP_PORT} -m 5 || true
echo "Deploy finished" >> /tmp/deploy_stage.log
EOF
)

# Replace placeholders in DO_DEPLOY_CMDS
DO_DEPLOY_CMDS="$(printf "%s" "$DO_DEPLOY_CMDS" | sed "s|${CONTAINER_NAME}|${CONTAINER_NAME}|g" | sed "s|${APP_PORT}|${APP_PORT}|g")"

log "Running deployment commands on remote"
# Use SSH to run the commands (passed via heredoc to avoid quoting issues)
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REM_USER@$REM_HOST" "bash -s" <<REMOTE_CMDS >> "$LOGFILE" 2>&1
$(printf "%s\n" "$DO_DEPLOY_CMDS")
REMOTE_CMDS

if [ $? -ne 0 ]; then
	  err "Remote deployment commands failed. Check $LOGFILE"
	    cleanup_local
	      exit 30
fi
log "Remote deployment commands executed."

# Validate externally (curl from local)
REMOTE_URL="http://$REM_HOST/"
log "Testing remote HTTP endpoint: $REMOTE_URL"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$REMOTE_URL" || echo "000")
if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "301" ] || [ "$HTTP_STATUS" = "302" ]; then
	  log "HTTP check OK (status $HTTP_STATUS)."
  else
	    err "HTTP check returned $HTTP_STATUS. Check remote logs and /tmp/deploy_stage.log on remote host."
	      # fetch remote log snippet
	        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$REM_USER@$REM_HOST" "sudo tail -n 200 /tmp/deploy_stage.log || sudo tail -n 200 /tmp/deploy_remote.log || true" >> "$LOGFILE" 2>&1 || true
		  cleanup_local
		    exit 40
fi

log "Deployment successful. Logs: $LOGFILE"
cleanup_local
exit 0

