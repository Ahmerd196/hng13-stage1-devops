# Automated Deployment Script (Stage 1) — deploy.sh

## Purpose
This repository includes `deploy.sh`, a POSIX-compatible Bash script that automates:
- cloning/pulling a GitHub repo using a PAT,
- preparing a remote server (Docker, docker-compose-plugin, Nginx),
- transferring files,
- deploying the app with Docker or Docker Compose,
- configuring Nginx as a reverse proxy,
- validating the deployment and logging results.

## Files
- `deploy.sh` — executable script for deployment.
- `README.md` — this file.

## Usage
1. Make script executable:
```bash
chmod +x deploy.sh

2. Run interactively:

./deploy.sh

3. Follow prompts:

Repo URL (HTTPS)

GitHub PAT (input hidden)

Branch (defaults to main)

Remote SSH user and host/IP

SSH private key path

Container internal port (e.g. 80 or 3000)

4. To remove deployed resources (cleanup):

./deploy.sh --cleanup

Notes / Security

The script uses rsync to transfer project files (excludes .git).

The PAT is used only for cloning; it is not printed to console or logs.

Ensure your SSH private key file has correct permissions (chmod 600 key.pem).

For production, review the script and adapt to your organization's security policies.

Requirements

Local machine: git, rsync, ssh, curl

Remote machine: Debian/Ubuntu recommended (apt-get available). Script tries to be tolerant but may need adjustments for other distros.

Troubleshooting

If ssh fails: check security groups (AWS), firewall, IP, key path.

If the remote service fails: check /tmp/deploy_stage.log and /tmp/deploy_remote.log on the remote host.

Author
Ahmad Abdurrahman Muhammad
---

# Quick notes / caveats & how to use safely

- The script runs remote installation via `curl https://get.docker.com | sh`. This is a convenient approach; for hardened environments you'd replace with vendor-verified installation steps.
- The script assumes Debian/Ubuntu remote OS for `apt-get` paths. Adjust package manager commands for other distros.
- The script proxies Nginx to `127.0.0.1:APP_PORT` and binds the container to that port on localhost. This avoids exposing container port publicly but still allows Nginx to route traffic.
- If your repo uses `docker-compose.yml`, the script uses `docker compose up -d --build`. If your app expects environment variables, volumes, or secrets, update the repo's compose file accordingly.
- For SSL: the script leaves a placeholder for Certbot and recommends adding Certbot/Let's Encrypt after DNS is configured.

---
```
