#!/bin/bash
set -euo pipefail
trap 'echo "[ERROR] Something went wrong at line $LINENO"; exit 1' ERR

LOG_FILE="./deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting deployment script..."

# === User Input Collection ===
read -rp "Git repo URL: " REPO_URL
while [[ -z "$REPO_URL" ]]; do
	    read -rp "Git repo URL cannot be empty. Enter again: " REPO_URL
    done

    read -rsp "GitHub Personal Access Token: " PAT
    echo
    while [[ -z "$PAT" ]]; do
	        read -rsp "PAT cannot be empty. Enter again: " PAT
		    echo
	    done

	    read -rp "Branch name [default: main]: " BRANCH
	    BRANCH=${BRANCH:-main}

	    read -rp "Remote SSH username: " SSH_USER
	    while [[ -z "$SSH_USER" ]]; do
		        read -rp "SSH username cannot be empty. Enter again: " SSH_USER
		done

		read -rp "Remote host/IP: " SSH_HOST
		while [[ -z "$SSH_HOST" ]]; do
			    read -rp "SSH host/IP cannot be empty. Enter again: " SSH_HOST
		    done

		    read -rp "SSH private key path: " SSH_KEY
		    while [[ ! -f "$SSH_KEY" ]]; do
			        read -rp "Invalid path. Enter full SSH private key path: " SSH_KEY
			done

			read -rp "Container internal port (e.g., 80): " CONTAINER_PORT
			CONTAINER_PORT=${CONTAINER_PORT:-80}

			# === Clone or Update Repository ===
			TMP_DIR=$(mktemp -d)
			echo "[INFO] Temporary directory: $TMP_DIR"

			REPO_NAME=$(basename "$REPO_URL" .git)
			if [[ -d "$TMP_DIR/$REPO_NAME" ]]; then
				    echo "[INFO] Repo exists. Pulling latest changes..."
				        git -C "$TMP_DIR/$REPO_NAME" fetch
					    git -C "$TMP_DIR/$REPO_NAME" checkout "$BRANCH"
					        git -C "$TMP_DIR/$REPO_NAME" pull
					else
						    echo "[INFO] Cloning $REPO_URL (branch: $BRANCH)..."
						        git clone -b "$BRANCH" "https://$PAT@${REPO_URL#https://}" "$TMP_DIR/$REPO_NAME"
			fi

			cd "$TMP_DIR/$REPO_NAME"
			if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
				    echo "[ERROR] No Dockerfile or docker-compose.yml found!"
				        exit 1
			fi

			# === Build Docker Image ===
			IMAGE_NAME="${REPO_NAME}_image"
			echo "[INFO] Building Docker image locally..."
		docker build -t "$IMAGE_NAME:latest" .

		# Save Docker image for transfer
		IMAGE_TAR="/tmp/${IMAGE_NAME}.tar"
	docker save "$IMAGE_NAME:latest" -o "$IMAGE_TAR"

	# === Deploy to Remote Server ===
	ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash -s <<'EOF'
set -euo pipefail

# === Variables inside remote session ===
IMAGE_NAME="${IMAGE_NAME:-deploy_hng13-stage1-devops}"
CONTAINER_PORT="${CONTAINER_PORT:-80}"
NGINX_CONF="/etc/nginx/sites-available/${IMAGE_NAME}"

# Update and install dependencies
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx

# Add user to Docker group if not already
if ! groups "$USER" | grep -q '\bdocker\b'; then
    sudo usermod -aG docker "$USER"
fi

# Ensure Docker and Nginx services are running
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

EOF

# Transfer Docker image
echo "[INFO] Transferring Docker image to remote..."
scp -i "$SSH_KEY" "$IMAGE_TAR" "$SSH_USER@$SSH_HOST:/tmp/"

# Run remote deployment commands
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" bash -s <<EOF
set -euo pipefail

IMAGE_NAME="$IMAGE_NAME"
CONTAINER_PORT="$CONTAINER_PORT"
NGINX_CONF="/etc/nginx/sites-available/\$IMAGE_NAME"

# Load Docker image
sudo docker load -i /tmp/${IMAGE_NAME}.tar

# Stop & remove old container if exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "\$IMAGE_NAME"; then
    sudo docker stop "\$IMAGE_NAME" || true
    sudo docker rm "\$IMAGE_NAME" || true
fi

# Run new container
sudo docker run -d --name "\$IMAGE_NAME" -p "\$CONTAINER_PORT:80" "\$IMAGE_NAME:latest"

# Setup Nginx reverse proxy
sudo tee "\$NGINX_CONF" > /dev/null <<NGINXCONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:\$CONTAINER_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXCONF

sudo ln -sf "\$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Validate deployment
sudo systemctl is-active --quiet nginx && echo "[INFO] Nginx is active"
sudo docker ps --filter "name=\$IMAGE_NAME"
EOF

echo "[INFO] Deployment complete!"

