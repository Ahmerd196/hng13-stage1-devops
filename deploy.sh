#!/bin/bash
set -e
trap 'echo "[ERROR] Something went wrong at line $LINENO"; exit 1' ERR

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
echo "[INFO] Deployment started at $(date)" | tee -a $LOG_FILE

# --- Check for cleanup flag ---
CLEANUP=false
if [[ "$1" == "--cleanup" ]]; then
	    CLEANUP=true
fi

# --- User Input ---
read -p "Git repo URL: " REPO_URL
[[ -z "$REPO_URL" ]] && { echo "[ERROR] Repo URL cannot be empty"; exit 1; }

read -s -p "GitHub Personal Access Token: " PAT
echo
[[ -z "$PAT" ]] && { echo "[ERROR] PAT cannot be empty"; exit 1; }

read -p "Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Remote SSH username (e.g., ubuntu): " SSH_USER
[[ -z "$SSH_USER" ]] && { echo "[ERROR] SSH username cannot be empty"; exit 1; }

read -p "Remote host/IP: " REMOTE_HOST
[[ -z "$REMOTE_HOST" ]] && { echo "[ERROR] Remote host cannot be empty"; exit 1; }

read -p "SSH private key path (full path): " SSH_KEY
[[ ! -f "$SSH_KEY" ]] && { echo "[ERROR] SSH key file not found"; exit 1; }

read -p "Container internal port (e.g., 80): " APP_PORT
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
	    echo "[ERROR] Invalid port number"; exit 1
fi

# --- Clone Repository ---
TMP_DIR=$(mktemp -d)
echo "[INFO] Created temporary directory: $TMP_DIR" | tee -a $LOG_FILE
git clone -b "$BRANCH" https://$PAT@${REPO_URL#https://} "$TMP_DIR/repo" | tee -a $LOG_FILE

cd "$TMP_DIR/repo"
[[ ! -f Dockerfile && ! -f docker-compose.yml ]] && { echo "[ERROR] Dockerfile or docker-compose.yml not found"; exit 1; }

# --- Build Docker Image Locally ---
IMAGE_NAME="deploy_$(basename $REPO_URL .git | tr - _)"
echo "[INFO] Building Docker image locally..." | tee -a $LOG_FILE
docker build -t $IMAGE_NAME:latest . | tee -a $LOG_FILE

# --- Save Docker Image ---
IMAGE_TAR="$TMP_DIR/$IMAGE_NAME.tar"
docker save -o "$IMAGE_TAR" $IMAGE_NAME:latest
echo "[INFO] Docker image saved to $IMAGE_TAR" | tee -a $LOG_FILE

# --- SSH and Remote Deployment ---
echo "[INFO] Checking SSH connection..." | tee -a $LOG_FILE
ssh -o BatchMode=yes -i "$SSH_KEY" "$SSH_USER@$REMOTE_HOST" "echo 'SSH connection successful'" | tee -a $LOG_FILE

echo "[INFO] Uploading Docker image..." | tee -a $LOG_FILE
scp -i "$SSH_KEY" "$IMAGE_TAR" "$SSH_USER@$REMOTE_HOST:/tmp/$IMAGE_NAME.tar" | tee -a $LOG_FILE

# --- Remote Script ---
REMOTE_SCRIPT=$(cat <<EOF
set -e

echo "[REMOTE] Preparing server..."
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx

# Add user to docker group
sudo usermod -aG docker $SSH_USER || true

# Cleanup option
if $CLEANUP; then
    echo "[REMOTE] Cleaning up all deployed resources..."
    sudo docker ps -aq | xargs -r sudo docker stop
    sudo docker ps -aq | xargs -r sudo docker rm
    sudo docker images -aq | xargs -r sudo docker rmi -f
    sudo rm -f /etc/nginx/sites-enabled/$IMAGE_NAME
    sudo rm -f /etc/nginx/sites-available/$IMAGE_NAME
    sudo systemctl reload nginx || true
    exit 0
fi

# Stop old container if exists
if sudo docker ps -q --filter "name=$IMAGE_NAME" | grep -q .; then
  echo "[REMOTE] Stopping existing container..."
  sudo docker stop $IMAGE_NAME
  sudo docker rm $IMAGE_NAME
fi

# Load and run new image
sudo docker load -i /tmp/$IMAGE_NAME.tar
if sudo docker ps -a --format '{{.Names}}' | grep -q "^$IMAGE_NAME\$"; then
  sudo docker rm $IMAGE_NAME || true
fi
sudo docker run -d --name $IMAGE_NAME -p $APP_PORT:$APP_PORT $IMAGE_NAME:latest

# Nginx reverse proxy
NGINX_CONF="/etc/nginx/sites-available/$IMAGE_NAME"
sudo bash -c "cat > \$NGINX_CONF" <<EOC
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
EOC

sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/$IMAGE_NAME
sudo nginx -t
sudo systemctl reload nginx

# Deployment Validation
echo "[REMOTE] Validating deployment..."
sudo systemctl status nginx | head -n 10
sudo docker ps | grep $IMAGE_NAME
EOF
)

ssh -i "$SSH_KEY" "$SSH_USER@$REMOTE_HOST" "$REMOTE_SCRIPT" | tee -a $LOG_FILE

echo "[INFO] Deployment completed successfully!" | tee -a $LOG_FILE

