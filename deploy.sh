#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===== Logging =====
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# ===== User Input =====
read -rp "Git repo URL: " REPO_URL
read -rp "GitHub Personal Access Token (input hidden): " -s GITHUB_TOKEN
echo
read -rp "Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}
read -rp "Remote SSH username (e.g., ubuntu): " SSH_USER
read -rp "Remote host/IP: " SSH_HOST
read -rp "SSH private key path (full path): " SSH_KEY
read -rp "Container internal port (app listens inside container, e.g., 80): " CONTAINER_PORT

# ===== Input Validation =====
if ! [[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]] || [ "$CONTAINER_PORT" -le 0 ] || [ "$CONTAINER_PORT" -gt 65535 ]; then
	    log "[ERROR] Invalid container port."
	        exit 1
fi

# ===== Git Operations =====
REPO_NAME=$(basename -s .git "$REPO_URL")
if [ -d "$REPO_NAME" ]; then
	    log "Repo exists, pulling latest changes..."
	        git -C "$REPO_NAME" fetch --all
		    git -C "$REPO_NAME" checkout "$BRANCH"
		        git -C "$REPO_NAME" pull origin "$BRANCH"
		else
			    log "Cloning repo $REPO_URL..."
			        git clone -b "$BRANCH" "$REPO_URL" "$REPO_NAME"
fi

# ===== Docker Build =====
log "Building Docker image..."
IMAGE_NAME="deploy_${REPO_NAME}"
docker build -t "$IMAGE_NAME:latest" "$REPO_NAME"
IMAGE_TAR="/tmp/${IMAGE_NAME}.tar"
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:latest"

# ===== SSH Connectivity Check =====
log "Testing SSH connection..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo 'SSH connection successful'" || { log "[ERROR] SSH failed"; exit 1; }

# ===== Transfer Docker image =====
log "Transferring Docker image to remote..."
scp -i "$SSH_KEY" "$IMAGE_TAR" "$SSH_USER@$SSH_HOST:/tmp/"

# ===== Remote Deployment =====
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash -s <<EOF
set -euo pipefail

# ===== Install packages =====
sudo apt-get update -y
sudo apt-get install -y docker.io nginx
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

# ===== Load Docker Image =====
docker load -i /tmp/$(basename "$IMAGE_TAR")

# ===== Stop existing container =====
if docker ps -q --filter "name=$IMAGE_NAME" | grep -q .; then
    docker rm -f "$IMAGE_NAME"
fi

# ===== Run container =====
docker run -d --name "$IMAGE_NAME" -p 80:$CONTAINER_PORT "$IMAGE_NAME:latest"

# ===== Nginx Reverse Proxy =====
NGINX_CONF="/etc/nginx/sites-available/$IMAGE_NAME"
sudo tee "$NGINX_CONF" > /dev/null <<NGINX
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$CONTAINER_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# ===== Deployment Validation =====
docker ps | grep "$IMAGE_NAME" >/dev/null || { echo "[ERROR] Container failed to start"; exit 1; }
systemctl is-active --quiet nginx || { echo "[ERROR] Nginx not running"; exit 1; }

# ===== Cleanup =====
rm -f /tmp/$(basename "$IMAGE_TAR")
EOF

log "Deployment completed successfully!"

