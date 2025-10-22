#!/usr/bin/env bash
set -euo pipefail

# ====== Logging ======
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting deployment script at $(date)"

# ====== Collect user input ======
read -rp "Git repo URL: " REPO_URL
read -rsp "GitHub Personal Access Token (PAT): " GITHUB_TOKEN
echo
read -rp "Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}
read -rp "Remote SSH username (e.g., ubuntu): " SSH_USER
read -rp "Remote host/IP: " SSH_HOST
read -rp "SSH private key path (full path, e.g., /home/user/.ssh/id_rsa): " SSH_KEY
read -rp "Container internal port (app listens inside container, e.g., 80): " APP_PORT

IMAGE_NAME="deploy_$(basename "$REPO_URL" .git | tr '/' '_')"
CONTAINER_NAME="$IMAGE_NAME"

TMP_DIR=$(mktemp -d)
echo "[INFO] Created temporary directory: $TMP_DIR"

# ====== Clone repo ======
echo "[INFO] Cloning repository $REPO_URL (branch: $BRANCH)"
git clone -b "$BRANCH" "https://$GITHUB_TOKEN@${REPO_URL#https://}" "$TMP_DIR/repo"

cd "$TMP_DIR/repo"

if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
	    echo "[ERROR] No Dockerfile or docker-compose.yml found!"
	        exit 1
fi

# ====== Build Docker image locally ======
echo "[INFO] Building Docker image locally..."
docker build -t "$IMAGE_NAME:latest" .

# ====== Save Docker image ======
IMAGE_TAR="$TMP_DIR/$IMAGE_NAME.tar"
echo "[INFO] Saving Docker image to $IMAGE_TAR"
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:latest"

# ====== Upload image to remote ======
echo "[INFO] Uploading Docker image to remote..."
scp -i "$SSH_KEY" "$IMAGE_TAR" "$SSH_USER@$SSH_HOST:/tmp/"

# ====== Deploy on remote ======
echo "[INFO] Executing deployment on remote server..."
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash -s <<EOF
set -euo pipefail

# Load Docker image
docker load -i /tmp/$IMAGE_NAME.tar

# Stop & remove existing container if running
if docker ps -a --format '{{.Names}}' | grep -Eq "^$CONTAINER_NAME\$"; then
    echo "[INFO] Stopping existing container $CONTAINER_NAME"
    docker stop $CONTAINER_NAME || true
    docker rm $CONTAINER_NAME || true
fi

# Run container
docker run -d --name $CONTAINER_NAME -p 80:$APP_PORT "$IMAGE_NAME:latest"

# Setup Nginx reverse proxy
sudo tee /etc/nginx/sites-available/$IMAGE_NAME > /dev/null <<NGINX_CONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_CONF

sudo ln -sf /etc/nginx/sites-available/$IMAGE_NAME /etc/nginx/sites-enabled/$IMAGE_NAME

# Test & reload Nginx
sudo nginx -t
sudo systemctl restart nginx

echo "[INFO] Deployment complete on remote server."
EOF

echo "[INFO] Deployment finished successfully."
echo "[INFO] Check the logs above or in $LOG_FILE for details."

