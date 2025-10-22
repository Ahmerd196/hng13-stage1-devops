#!/bin/bash
# deploy.sh - HNG DevOps Stage 1 Task
set -euo pipefail
trap 'echo "[ERROR] Something went wrong at line $LINENO"; exit 1' ERR

# --- Logging ---
log() {
	  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  }

# --- Cleanup flag ---
CLEANUP=false
for arg in "$@"; do
	  [[ "$arg" == "--cleanup" ]] && CLEANUP=true
  done

  # --- User Input ---
  read -p "Git repo URL: " repo
  if [[ ! "$repo" =~ ^https?:// ]]; then
	    echo "[ERROR] Invalid Git URL"; exit 1
  fi

  read -s -p "GitHub Personal Access Token: " token; echo
  read -p "Branch name [default: main]: " branch
  branch=${branch:-main}

  read -p "Remote SSH username (e.g., ubuntu): " ssh_user
  read -p "Remote host/IP: " host
  read -p "SSH private key path (full path, e.g., /home/user/.ssh/id_rsa): " ssh_key
  if [[ ! -f "$ssh_key" ]]; then
	    echo "[ERROR] SSH key not found"; exit 1
  fi

  read -p "Container internal port (e.g., 80): " app_port
  if ! [[ "$app_port" =~ ^[0-9]+$ ]]; then
	    echo "[ERROR] Port must be numeric"; exit 1
  fi

  container_name=$(basename "$repo" .git)
  tmp_dir=$(mktemp -d)
  log "Created temporary directory: $tmp_dir"

  # --- Git Operations ---
  cd "$tmp_dir"
  if [ -d "$container_name" ]; then
	    cd "$container_name"
	      git fetch
	        git checkout "$branch"
		  git pull origin "$branch"
	  else
		    git clone -b "$branch" "https://$token@${repo#https://}" "$container_name"
  fi
  cd "$container_name"

  # --- Docker Build ---
  if [ ! -f Dockerfile ]; then
	    log "No Dockerfile found, exiting"; exit 1
  fi
  log "Building Docker image locally..."
docker build -t "$container_name:latest" .

# --- SSH Connectivity Check ---
if ! ssh -i "$ssh_key" "$ssh_user@$host" "echo 1" &>/dev/null; then
	  echo "[ERROR] SSH connection failed"; exit 1
fi
log "SSH connection successful"

# --- Optional Cleanup ---
if [ "$CLEANUP" = true ]; then
	  log "Running cleanup on remote..."
	    ssh -i "$ssh_key" "$ssh_user@$host" "
	        docker stop $container_name || true
		    docker rm $container_name || true
		        docker rmi $container_name:latest || true
			    sudo rm -f /etc/nginx/sites-enabled/$container_name
			        sudo rm -f /etc/nginx/sites-available/$container_name
				  "
				    log "Cleanup complete"
				      exit 0
fi

# --- Transfer Docker image ---
docker save "$container_name:latest" | bzip2 | ssh -i "$ssh_key" "$ssh_user@$host" "bunzip2 | docker load"

# --- Remote Deployment ---
ssh -i "$ssh_key" "$ssh_user@$host" bash <<EOF
set -euo pipefail
# Stop & remove old container
docker stop $container_name || true
docker rm $container_name || true

# Run container
docker run -d --name $container_name -p $app_port:$app_port $container_name:latest

# Install Docker & Nginx if missing
if ! command -v docker >/dev/null; then
  sudo apt update
  sudo apt install -y docker.io
fi
if ! command -v nginx >/dev/null; then
  sudo apt install -y nginx
fi
sudo systemctl enable docker nginx
sudo systemctl start docker nginx

# Configure Nginx reverse proxy
cat <<NGINX > /tmp/$container_name.nginx
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$app_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX

sudo mv /tmp/$container_name.nginx /etc/nginx/sites-available/$container_name
sudo ln -sf /etc/nginx/sites-available/$container_name /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Validate deployment
docker ps | grep $container_name
curl -s http://127.0.0.1 | head -n 5
EOF

log "Deployment complete!"

