#!/usr/bin/env bash
# One-shot setup for AIAvatar using micromamba env "aiavt":
#   - Creates or updates conda env from environment-aiavt.yml + requirements.txt
#   - Optionally installs Ollama (macOS + Homebrew) and pulls the LLM from config.yml
#
# Usage:
#   ./scripts/setup_aiavt.sh
#   INSTALL_OLLAMA=0 ./scripts/setup_aiavt.sh   # skip Homebrew ollama install (still runs ollama pull if ollama exists)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${MAMBA_ENV_NAME:-aiavt}"
PREFIX="${MAMBA_ROOT_PREFIX:-${HOME}/micromamba}/envs/${ENV_NAME}"

cd "$ROOT"

if ! command -v micromamba &>/dev/null; then
  echo "micromamba not found. Install: https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html"
  exit 1
fi

echo "==> Project: ${ROOT}"
echo "==> Micromamba env: ${ENV_NAME} (prefix: ${PREFIX})"

if [[ -d "${PREFIX}" ]]; then
  echo "==> Updating existing env ${ENV_NAME}..."
  micromamba env update -n "${ENV_NAME}" -f "${ROOT}/environment-aiavt.yml" -y
else
  echo "==> Creating env ${ENV_NAME}..."
  micromamba env create -f "${ROOT}/environment-aiavt.yml" -y
fi

echo "==> pip install -r requirements.txt"
micromamba run -n "${ENV_NAME}" python -m pip install -U pip setuptools wheel
micromamba run -n "${ENV_NAME}" pip install -r "${ROOT}/requirements.txt"

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
  echo "==> Linux: install Ollama with:"
  echo "    curl -fsSL https://ollama.com/install.sh | sh"
  echo "    (re-run this script after install), or set INSTALL_OLLAMA=0 if you install it yourself."
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
