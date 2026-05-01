#!/usr/bin/env bash
# Push AIAvatar to a Vast.ai box. Your public key must be in the instance authorized_keys
# (Vast account SSH keys + instance created/restarted after adding the key).
#
# Two tunnel endpoints for the same VM (from dashboard); use either:
#   Proxy:  ssh -p 27125 root@ssh3.vast.ai -L 8080:localhost:8080
#   Direct: ssh -p 45634 root@38.117.87.41 -L 8080:localhost:8080
#
# Usage:
#   SSH_KEY=~/.ssh/id_ed25519 ./scripts/rsync_to_vast.sh
#   SSH_HOST=ssh3.vast.ai SSH_PORT=27125 SSH_KEY=~/.ssh/id_ed25519 ./scripts/rsync_to_vast.sh
#   SSH_HOST=38.117.87.41 SSH_PORT=45634 SSH_KEY=~/.ssh/id_ed25519 ./scripts/rsync_to_vast.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH_HOST="${SSH_HOST:-ssh3.vast.ai}"
SSH_PORT="${SSH_PORT:-27125}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
REMOTE="${REMOTE:-root@${SSH_HOST}:~/AIAvatar/}"

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "Private key not found: ${SSH_KEY}" >&2
  echo "Set SSH_KEY to your ed25519 key for this instance." >&2
  exit 1
fi

rsync -avz --progress \
  -e "ssh -p ${SSH_PORT} -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new" \
  --exclude '/data/' \
  --exclude '/models/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  "${ROOT}/" \
  "${REMOTE}"

echo ""
echo "Synced. On the GPU host run:"
echo "  cd ~/AIAvatar && ./scripts/setup_aiavt.sh"
echo "(Re-rsync after local edits before re-running setup.)"
