#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------
# Simple logging function
# ----------------------------------------
log() {
	    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    }

# ----------------------------------------
# Error handler
# ----------------------------------------
error_exit() {
	    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
	        exit 1
	}
trap 'error_exit "An unexpected error occurred."' ERR

# ----------------------------------------
# User input collection with validation
# ----------------------------------------
read -rp "Git repo URL: " GIT_REPO
[[ -z "$GIT_REPO" ]] && error_exit "Git repo URL cannot be empty"

read -rsp "GitHub Personal Access Token: " GIT_TOKEN
echo
[[ -z "$GIT_TOKEN" ]] && error_exit "Personal Access Token cannot be empty"

read -rp "Branch name [default: main]: " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}

read -rp "Remote SSH username: " SSH_USER
[[ -z "$SSH_USER" ]] && error_exit "SSH username cannot be empty"

read -rp "Remote host/IP: " SSH_HOST
[[ -z "$SSH_HOST" ]] && error_exit "Remote host/IP cannot be empty"

read -rp "SSH private key path: " SSH_KEY
[[ ! -f "$SSH_KEY" ]] && error_exit "SSH private key not found at $SSH_KEY"

read -rp "Container internal port (inside container): " APP_PORT
[[ -z "$APP_PORT" ]] && error_exit "App port cannot be empty"

# Temporary directory for build
TMP_DIR=$(mktemp -d)
log "Created temporary directory: $TMP_DIR"

# Clone the repo
log "Cloning repository $GIT_REPO (branch: $GIT_BRANCH)"
git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$TMP_DIR/repo"

# Build Docker image locally
IMAGE_NAME="deploy_hng13_stage1_devops"
log "Building Docker image locally..."
docker build -t "$IMAGE_NAME:latest" "$TMP_DIR/repo"

# Save Docker image to tar
IMAGE_TAR="$TMP_DIR/${IMAGE_NAME}.tar"
log "Saving Docker image to $IMAGE_TAR"
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:latest"

# SSH command prefix
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST"

# ----------------------------------------
# Remote setup
# ----------------------------------------
log "Preparing remote server..."

$SSH_CMD bash -c "'
set -e
# Update packages
sudo apt-get update

# Remove conflicting containerd packages
sudo apt-get remove -y containerd containerd.io || true

# Install required packages and Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release nginx

# Add Docker GPG key
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Setup Docker repo
echo \
	  \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
	    https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | \
	      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ensure docker group
sudo usermod -aG docker $SSH_USER || true

# Start Nginx
sudo systemctl enable nginx
sudo systemctl start nginx
'"

# ----------------------------------------
# Transfer Docker image
# ----------------------------------------
log "Transferring Docker image to remote..."
scp -i "$SSH_KEY" "$IMAGE_TAR" "$SSH_USER@$SSH_HOST:/tmp/"

# ----------------------------------------
# Remote Docker load and run
# ----------------------------------------
log "Deploying container on remote..."
$SSH_CMD bash -c "'
set -e

IMAGE_NAME=\"$IMAGE_NAME:latest\"

# Load image
sudo docker load -i /tmp/${IMAGE_NAME}.tar

# Stop and remove old container if exists
if sudo docker ps -aq --filter name=$IMAGE_NAME | grep -q .; then
	    sudo docker stop $IMAGE_NAME || true
	        sudo docker rm $IMAGE_NAME || true
		fi

		# Run container
		sudo docker run -d --name $IMAGE_NAME -p 80:$APP_PORT $IMAGE_NAME:latest
		'"

		# ----------------------------------------
		# Configure Nginx as reverse proxy
		# ----------------------------------------
		log "Configuring Nginx reverse proxy..."
		NGINX_CONF="server {
		    listen 80;
		        server_name _;
			    location / {
			            proxy_pass http://127.0.0.1:$APP_PORT;
				            proxy_set_header Host \$host;
					            proxy_set_header X-Real-IP \$remote_addr;
						            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
							        }
						}"

					echo "$NGINX_CONF" > "$TMP_DIR/nginx.conf"

					scp -i "$SSH_KEY" "$TMP_DIR/nginx.conf" "$SSH_USER@$SSH_HOST:/tmp/deploy_nginx.conf"

					$SSH_CMD bash -c "'
					set -e
					sudo mv /tmp/deploy_nginx.conf /etc/nginx/sites-available/deploy_hng13_stage1
					sudo ln -sf /etc/nginx/sites-available/deploy_hng13_stage1 /etc/nginx/sites-enabled/deploy_hng13_stage1
					sudo nginx -t
					sudo systemctl reload nginx
					'"

					log "Deployment completed successfully!"

