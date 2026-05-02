#!/usr/bin/env bash
set -euo pipefail

echo "WARNING: this will DELETE containers, images, volumes, cache BUT KEEP networks."
echo "Press Ctrl+C now to cancel, or Enter to continue."
read -r

echo "[1/6] Stopping Docker services..."
systemctl stop docker.socket 2>/dev/null || true
systemctl stop docker.service 2>/dev/null || true
systemctl stop containerd.service 2>/dev/null || true

echo "[2/6] Starting Docker temporarily for cleanup..."
systemctl start containerd.service 2>/dev/null || true
systemctl start docker.service

echo "[3/6] Removing containers..."
docker rm -f $(docker ps -aq) 2>/dev/null || true

echo "[4/6] Removing images..."
docker rmi -f $(docker images -aq) 2>/dev/null || true

echo "[5/6] Removing volumes..."
docker volume rm $(docker volume ls -q) 2>/dev/null || true

echo "[6/6] Cleaning build cache..."
docker builder prune -a -f

echo
echo "Docker cleaned. Networks preserved."

docker network ls
