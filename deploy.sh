#!/bin/bash
# ==========================================================
# HNG Stage 1 DevOps Task - Automated Deployment Script
# Author: Ahmad Abdurrahman Muhammad
# ==========================================================
set -euo pipefail
trap 'echo "[ERROR] Unexpected error on line $LINENO."; exit 1' ERR

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting deployment..."

# === 1. Collect Parameters ===
read -p "Enter Git Repository URL: " GIT_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}
read -p "Enter Remote Server Username: " SSH_USER
read -p "Enter Remote Server IP: " SSH_IP
read -p "Enter SSH Key Path (e.g., ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter Application Port (unused port, e.g., 8080): " APP_PORT
APP_PORT=${APP_PORT:-8080}

# === 2. Clone Repository ===
REPO_DIR=$(basename "$GIT_URL" .git)
if [ -d "$REPO_DIR" ]; then
	  echo "[INFO] Repo exists, pulling latest changes..."
	    cd "$REPO_DIR"
	      git pull origin "$BRANCH"
      else
	        echo "[INFO] Cloning repository..."
		  git clone -b "$BRANCH" "https://${PAT}@${GIT_URL#https://}" "$REPO_DIR"
		    cd "$REPO_DIR"
fi

# === 3. Verify Project Structure ===
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
	  echo "[SUCCESS] Docker configuration found."
  else
	    echo "[ERROR] No Dockerfile or docker-compose.yml found."
	      exit 1
fi

# === 4. Remote Server Connectivity Check ===
echo "[INFO] Checking SSH connectivity..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${SSH_IP}" "echo Connected OK" || {
	  echo "[ERROR] SSH connection failed."
  exit 1
}

# === 5. Prepare Remote Environment ===
echo "[INFO] Preparing remote environment..."
ssh -i "$SSH_KEY" "${SSH_USER}@${SSH_IP}" bash <<EOF
set -e
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg nginx
sudo mkdir -p /etc/apt/keyrings
if ! command -v docker &>/dev/null; then
  echo "[INFO] Installing Docker..."
  sudo apt-get remove -y containerd.io || true
  curl -fsSL https://get.docker.com | sh
fi
if ! command -v docker-compose &>/dev/null; then
  echo "[INFO] Installing Docker Compose..."
  sudo apt-get install -y docker-compose
fi
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker \$USER
EOF

# === 6. Deploy Dockerized App ===
echo "[INFO] Deploying application..."
rsync -avz -e "ssh -i $SSH_KEY" ./ "${SSH_USER}@${SSH_IP}:/home/${SSH_USER}/${REPO_DIR}"

ssh -i "$SSH_KEY" "${SSH_USER}@${SSH_IP}" bash <<EOF
set -e
cd /home/${SSH_USER}/${REPO_DIR}

# Stop any previous container
docker ps -q --filter "name=hng13-stage1-devops-web" | grep -q . && \
  docker stop hng13-stage1-devops-web && docker rm hng13-stage1-devops-web || true

# Free the port
sudo fuser -k ${APP_PORT}/tcp || true

# Build and Run container
docker build -t hng13-stage1-devops-web .
docker run -d -p ${APP_PORT}:80 --name hng13-stage1-devops-web hng13-stage1-devops-web

# Validate container
sleep 5
docker ps | grep hng13-stage1-devops-web && echo "[SUCCESS] Container is running on port ${APP_PORT}"
EOF

# === 7. Configure Nginx Reverse Proxy (Fixed Escape Issue) ===
echo "[INFO] Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "${SSH_USER}@${SSH_IP}" bash <<EOF
set -e
sudo tee /etc/nginx/sites-available/hng13-stage1-devops.conf > /dev/null <<'NGINX_CONF'
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
NGINX_CONF
sudo ln -sf /etc/nginx/sites-available/hng13-stage1-devops.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
EOF

# === 8. Validate Deployment ===
echo "[INFO] Validating deployment..."
ssh -i "$SSH_KEY" "${SSH_USER}@${SSH_IP}" bash <<EOF
set -e
docker ps | grep hng13-stage1-devops-web || { echo "[ERROR] Docker container not running"; exit 1; }
sudo systemctl is-active --quiet nginx && echo "[SUCCESS] Nginx is active."
curl -I http://127.0.0.1 | head -n 1
EOF

echo "[SUCCESS] Deployment complete!"
echo "Access your app at: http://${SSH_IP}"
echo "Container Port: ${APP_PORT}"
echo "Log file: ${LOG_FILE}"

