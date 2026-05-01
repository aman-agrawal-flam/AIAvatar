#!/usr/bin/env bash
# One-shot setup for AIAvatar using micromamba env "aiavt":
#   - Creates or updates conda env from environment-aiavt.yml + requirements.txt
#   - Optionally installs Ollama (macOS + Homebrew) and pulls the LLM from config.yml
#
# micromamba is NOT in apt. If missing, this script installs the official binary to
#   ~/.local/bin (non-interactive) unless AUTO_INSTALL_MICROMAMBA=0.
#
# Usage:
#   ./scripts/setup_aiavt.sh
#   INSTALL_OLLAMA=0 ./scripts/setup_aiavt.sh   # skip Homebrew ollama install (still runs ollama pull if ollama exists)
#   AUTO_INSTALL_MICROMAMBA=0 ./scripts/setup_aiavt.sh   # fail if micromamba missing (no bootstrap)
#   PREFETCH_ASSETS=0 ./scripts/setup_aiavt.sh           # skip wav2lip.pth + avatar HF downloads
#   PREFETCH_ASSETS_EXTRA='--models-only' ./scripts/setup_aiavt.sh   # only wav2lip.pth (~215MB)
#   INSTALL_OLLAMA_LINUX_AUTO=1 ./scripts/setup_aiavt.sh # Linux: curl ollama install.sh (Vast)
#
# Remote GPU (e.g. Vast.ai): on your laptop, push the repo first, then SSH and run this here:
#   ./scripts/rsync_to_vast.sh   # or set SSH_HOST / SSH_PORT for your instance
#   ssh -p <PORT> -i ~/.ssh/id_ed25519 root@<HOST>
#   cd ~/AIAvatar && ./scripts/setup_aiavt.sh
#
#   AIAVT_SKIP_RSYNC_HINT=1 ./scripts/setup_aiavt.sh   # omit the rsync reminder on Linux
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${MAMBA_ENV_NAME:-aiavt}"
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-${HOME}/micromamba}"
PREFIX="${MAMBA_ROOT_PREFIX}/envs/${ENV_NAME}"
MICROMAMBA_BIN="${MICROMAMBA_BIN:-${HOME}/.local/bin/micromamba}"

cd "$ROOT"

if [[ "$(uname -s)" == "Linux" ]] && [[ -z "${AIAVT_SKIP_RSYNC_HINT:-}" ]]; then
  echo "==> Tip: after editing on your Mac, run ./scripts/rsync_to_vast.sh before setup so this copy stays current."
fi

ensure_micromamba() {
  if command -v micromamba &>/dev/null; then
    return 0
  fi
  if [[ -x "${MICROMAMBA_BIN}" ]]; then
    export PATH="$(dirname "${MICROMAMBA_BIN}"):${PATH}"
    return 0
  fi
  if [[ "${AUTO_INSTALL_MICROMAMBA:-1}" == "0" ]]; then
    echo "micromamba not found. Install: https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html" >&2
    echo "Or run without AUTO_INSTALL_MICROMAMBA=0 to auto-install to ~/.local/bin" >&2
    exit 1
  fi
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    echo "Need curl or wget to bootstrap micromamba. E.g. apt-get update && apt-get install -y curl" >&2
    exit 1
  fi
  echo "==> micromamba not found; installing official binary to ${HOME}/.local/bin (INIT_YES=no)..."
  mkdir -p "${HOME}/.local/bin"
  export BIN_FOLDER="${HOME}/.local/bin"
  export INIT_YES="${MICROMAMBA_INIT_YES:-no}"
  export CONDA_FORGE_YES=yes
  curl -fsSL https://micro.mamba.pm/install.sh | sh
  export PATH="${BIN_FOLDER}:${PATH}"
  if ! command -v micromamba &>/dev/null; then
    echo "micromamba still not on PATH after install; add ${BIN_FOLDER} to PATH" >&2
    exit 1
  fi
}

ensure_micromamba

echo "==> Project: ${ROOT}"
echo "==> Micromamba env: ${ENV_NAME} (prefix: ${PREFIX})"

# micromamba's install.sh sets channel_priority strict; flexible avoids unsatisfiable torch stacks.
MAMBA_ENV_FLAGS=(--channel-priority flexible)

if [[ -d "${PREFIX}" ]]; then
  echo "==> Updating existing env ${ENV_NAME}..."
  # env update has no --channel-priority; `update` does.
  micromamba update -n "${ENV_NAME}" -f "${ROOT}/environment-aiavt.yml" -y "${MAMBA_ENV_FLAGS[@]}"
else
  echo "==> Creating env ${ENV_NAME}..."
  micromamba env create -f "${ROOT}/environment-aiavt.yml" -y "${MAMBA_ENV_FLAGS[@]}"
fi

echo "==> pip install -r requirements.txt"
micromamba run -n "${ENV_NAME}" python -m pip install -U pip setuptools wheel
micromamba run -n "${ENV_NAME}" pip install -r "${ROOT}/requirements.txt"

# wav2lip.pth + avatar zips — rsync excludes /models/ and /data/; prefetch here for GPU hosts.
if [[ "${PREFETCH_ASSETS:-1}" == "1" ]]; then
  echo "==> Prefetch HF assets (wav2lip.pth + avatars). PREFETCH_ASSETS=0 to skip."
  echo "    Models-only: PREFETCH_ASSETS_EXTRA='--models-only'"
  micromamba run -n "${ENV_NAME}" python "${ROOT}/scripts/download_assets.py" ${PREFETCH_ASSETS_EXTRA:-} || {
    echo "WARNING: prefetch failed (network?). main.py will retry downloads on first run."
  }
fi

OLLAMA_MODEL="$(SETUP_ROOT="${ROOT}" python3 - <<'PY'
import os, re, pathlib
root = os.environ["SETUP_ROOT"]
text = pathlib.Path(root, "config.yml").read_text(encoding="utf-8")
m = re.search(r"LLM_MODEL_NAME:\s*\"?([^\"#\n]+)", text)
print(m.group(1).strip() if m else "llama3.2")
PY
)"
echo "==> LLM model from config.yml: ${OLLAMA_MODEL}"

install_ollama_macos() {
  if command -v ollama &>/dev/null; then
    echo "==> Ollama already on PATH"
    return 0
  fi
  if [[ "${INSTALL_OLLAMA:-1}" == "0" ]]; then
    echo "==> Skipping Ollama install (INSTALL_OLLAMA=0). Install from https://ollama.com"
    return 0
  fi
  if command -v brew &>/dev/null; then
    echo "==> Installing Ollama via Homebrew..."
    brew install ollama
    echo "==> Starting Ollama service (brew services)..."
    brew services start ollama || true
    sleep 2
  else
    echo "Homebrew not found. Install Ollama manually: https://ollama.com/download"
    return 0
  fi
}

install_ollama_linux() {
  if command -v ollama &>/dev/null; then
    echo "==> Ollama already on PATH"
    return 0
  fi
  if [[ "${INSTALL_OLLAMA:-1}" == "0" ]]; then
    echo "==> Skipping Ollama install (INSTALL_OLLAMA=0)."
    return 0
  fi
  if [[ "${INSTALL_OLLAMA_LINUX_AUTO:-0}" == "1" ]]; then
    echo "==> INSTALL_OLLAMA_LINUX_AUTO=1: running https://ollama.com/install.sh"
    curl -fsSL https://ollama.com/install.sh | sh || {
      echo "WARNING: Ollama install script failed."
      return 0
    }
    return 0
  fi
  echo "==> Linux: install Ollama with:"
  echo "    curl -fsSL https://ollama.com/install.sh | sh"
  echo "    Or auto: INSTALL_OLLAMA_LINUX_AUTO=1 ./scripts/setup_aiavt.sh"
  echo "    (re-run after install), or set INSTALL_OLLAMA=0 to silence this."
}

case "$(uname -s)" in
  Darwin) install_ollama_macos ;;
  Linux)  install_ollama_linux ;;
  *)      echo "==> Unknown OS; install Ollama manually if needed." ;;
esac

# Homebrew often installs outside a minimal PATH
case "$(uname -s)" in
  Darwin) export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}" ;;
esac

# Docker/Vast images often have no systemd after install.sh — ollama binary exists but nothing listens on :11434.
ensure_ollama_serve_linux() {
  [[ "$(uname -s)" != "Linux" ]] && return 0
  command -v ollama &>/dev/null || return 0
  if curl -fsS --connect-timeout 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Ollama installed but API not up (no systemd?). Starting: nohup ollama serve"
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  local i
  for i in $(seq 1 15); do
    if curl -fsS --connect-timeout 1 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      echo "==> Ollama listening on 127.0.0.1:11434"
      return 0
    fi
    sleep 1
  done
  echo "WARNING: ollama serve did not become ready; check /tmp/ollama-serve.log"
}

ensure_ollama_serve_linux

if command -v ollama &>/dev/null; then
  echo "==> ollama pull ${OLLAMA_MODEL} (first download can take several minutes)"
  ollama pull "${OLLAMA_MODEL}" || {
    echo "WARNING: ollama pull failed (network or unknown tag). Fix and run: ollama pull ${OLLAMA_MODEL}"
  }
else
  echo "==> Ollama not on PATH; after installing run: ollama pull ${OLLAMA_MODEL}"
fi

echo ""
echo "Done."
echo "  micromamba activate ${ENV_NAME}"
echo "  cd \"${ROOT}\""
echo "  ./run.sh"
echo ""
echo "config.yml expects Ollama at http://127.0.0.1:11434/v1 and model \"${OLLAMA_MODEL}\"."
