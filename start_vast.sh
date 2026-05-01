#!/usr/bin/env bash
# From your Mac: sync AIAvatar to Vast, start the server on the GPU, SSH tunnel, open UI.
#
# Required:
#   export VAST_HOST=38.117.87.41
#   export VAST_PORT=45634
# Optional:
#   SSH_KEY=~/.ssh/id_ed25519
#   LOCAL_WEB_PORT=8010   REMOTE_WEB_PORT=8010
#   AVATAR_ID=wav2lip_avatar_female_model
#   SKIP_RSYNC=1          skip rsync (only tunnel + ensure server)
#   OPEN_BROWSER=1        macOS: open Safari/Chrome on the UI URL (default on)
#   AUTO_SETUP=1          if aiavt env missing on Vast, run setup_aiavt.sh then start (first GPU run)
#
# Usage:
#   ./start_vast.sh
#   ./start_vast.sh --bootstrap   # same as AUTO_SETUP=1: create aiavt on Vast if missing (recommended first time)
#   ./start_vast.sh --setup       # always run setup_aiavt.sh on Vast (slow; refreshes env)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VAST_HOST="${VAST_HOST:-${SSH_HOST:-}}"
VAST_PORT="${VAST_PORT:-${SSH_PORT:-}}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
# Absolute path on the *remote* (Vast default user is root).
REMOTE_DIR="${REMOTE_DIR:-/root/AIAvatar}"
LOCAL_WEB_PORT="${LOCAL_WEB_PORT:-8010}"
REMOTE_WEB_PORT="${REMOTE_WEB_PORT:-8010}"
AVATAR_ID="${AVATAR_ID:-wav2lip_avatar_female_model}"
OPEN_BROWSER="${OPEN_BROWSER:-1}"

RUN_SETUP=0
REMOTE_AUTO_SETUP="${AUTO_SETUP:-0}"
for arg in "$@"; do
  case "$arg" in
    --setup) RUN_SETUP=1 ;;
    --bootstrap) REMOTE_AUTO_SETUP=1 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${VAST_HOST}" ]] || die "Set VAST_HOST (and VAST_PORT) to your Vast SSH host."
[[ -n "${VAST_PORT}" ]] || die "Set VAST_PORT to your Vast SSH port."
[[ -f "${SSH_KEY}" ]] || die "SSH private key not found: ${SSH_KEY}"

SSH_BASE=(ssh -p "${VAST_PORT}" -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new "root@${VAST_HOST}")

rsync_project() {
  echo "==> rsync → root@${VAST_HOST}:${REMOTE_DIR}"
  # Exclude only root ./data and ./weights dir; leading / is transfer-root anchor (not src/wav2lip/models).
  rsync -avz --progress \
    -e "ssh -p ${VAST_PORT} -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new" \
    --exclude '/data/' \
    --exclude '/models/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "${ROOT}/" \
    "root@${VAST_HOST}:${REMOTE_DIR}/"
}

remote_setup() {
  echo "==> remote: ./scripts/setup_aiavt.sh (may take a long time)"
  "${SSH_BASE[@]}" bash -lc "cd ${REMOTE_DIR} && export PATH=\"\${HOME}/.local/bin:\${PATH}\" && ./scripts/setup_aiavt.sh"
}

remote_start_server() {
  echo "==> remote: start ./run.sh (${AVATAR_ID} port ${REMOTE_WEB_PORT})"
  "${SSH_BASE[@]}" bash -s "${REMOTE_DIR}" "${REMOTE_WEB_PORT}" "${AVATAR_ID}" "${REMOTE_AUTO_SETUP}" <<'REMOTE_EOF'
set -euo pipefail
REMOTE_DIR="$1"
REMOTE_WEB_PORT="$2"
AVATAR_ID="$3"
REMOTE_AUTO_SETUP="$4"
cd "${REMOTE_DIR}" || exit 1
export PATH="${HOME}/.local/bin:${PATH}"
command -v micromamba >/dev/null 2>&1 || { echo "micromamba not found"; exit 1; }
MROOT="${MAMBA_ROOT_PREFIX:-${HOME}/micromamba}"
# aiavt may live under micromamba (${MROOT}/envs/aiavt) or a fixed prefix like /venv/aiavt on some GPU images.
aiavt_ok() {
  micromamba run -n aiavt python -c "pass" 2>/dev/null && return 0
  [[ -x "/venv/aiavt/bin/python" ]] && return 0
  return 1
}
if ! aiavt_ok; then
  if [[ "${REMOTE_AUTO_SETUP}" == "1" ]]; then
    echo "==> aiavt not usable yet — running ./scripts/setup_aiavt.sh ..."
    ./scripts/setup_aiavt.sh
  else
    echo "aiavt not found: neither \`micromamba run -n aiavt\` nor /venv/aiavt/bin/python works."
    echo "(Expected mic env at ${MROOT}/envs/aiavt or Python at /venv/aiavt on some hosts.)"
    echo "First time on this GPU:"
    echo "  ./start_vast.sh --bootstrap"
    exit 1
  fi
fi
# How to invoke ./run.sh: micromamba wrapper vs PATH to /venv/aiavt (run.sh picks python from PATH).
if micromamba run -n aiavt python -c "pass" 2>/dev/null; then
  LAUNCH_CMD=(micromamba run -n aiavt)
else
  export PATH="/venv/aiavt/bin:${PATH}"
  LAUNCH_CMD=()
  echo "==> Using /venv/aiavt on PATH (micromamba name 'aiavt' not linked there)."
fi
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "sport = :${REMOTE_WEB_PORT}" 2>/dev/null | grep -q LISTEN; then
    echo "Port ${REMOTE_WEB_PORT} already listening on Vast — leaving existing server running."
    exit 0
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -tln 2>/dev/null | grep -q ":${REMOTE_WEB_PORT}"; then
    echo "Port ${REMOTE_WEB_PORT} already listening — leaving existing server running."
    exit 0
  fi
fi
nohup "${LAUNCH_CMD[@]}" ./run.sh "${AVATAR_ID}" "${REMOTE_WEB_PORT}" >/tmp/aiavatar-run.log 2>&1 &
echo $! >/tmp/aiavatar-run.pid
sleep 2
echo "--- tail /tmp/aiavatar-run.log ---"
tail -n 25 /tmp/aiavatar-run.log || true
REMOTE_EOF
}

ensure_tunnel() {
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"${LOCAL_WEB_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "==> localhost:${LOCAL_WEB_PORT} already in use — skipping new tunnel (reuse existing)."
      return 0
    fi
  fi
  echo "==> SSH tunnel: localhost:${LOCAL_WEB_PORT} → Vast localhost:${REMOTE_WEB_PORT}"
  ssh -p "${VAST_PORT}" -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
    -f -N -L "${LOCAL_WEB_PORT}:127.0.0.1:${REMOTE_WEB_PORT}" \
    "root@${VAST_HOST}"
}

[[ "${SKIP_RSYNC:-0}" == "1" ]] || rsync_project
[[ "${RUN_SETUP}" == "1" ]] && remote_setup
remote_start_server
ensure_tunnel

URL="http://127.0.0.1:${LOCAL_WEB_PORT}/index.html"
echo ""
echo "Open in browser: ${URL}"
echo "Logs on Vast:     ssh ... 'tail -f /tmp/aiavatar-run.log'"
echo ""

if [[ "$(uname -s)" == "Darwin" ]] && [[ "${OPEN_BROWSER}" == "1" ]]; then
  open "${URL}" || true
fi

echo ""
echo "Launcher finished (this is normal). The app keeps running on Vast under nohup;"
echo "the SSH tunnel stays open in the background (-f -N). To watch logs:"
echo "  ssh -p ${VAST_PORT} -i ${SSH_KEY} root@${VAST_HOST} 'tail -f /tmp/aiavatar-run.log'"
