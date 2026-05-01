# End-to-end: AIAvatar on Vast.ai (from macOS)

This flow matches the repo defaults: **local LLM via Ollama**, **Edge TTS**, **Wav2Lip** on the GPU, Web UI on port **8010**.

## What gets synced vs downloaded

| Content | How it reaches the GPU |
|--------|-------------------------|
| Python code, `config.yml`, `src/wav2lip/**` | **rsync** (`start_vast.sh` / `scripts/rsync_to_vast.sh`) |
| **`models/wav2lip.pth`** (~215 MB) | **Not rsync’d** (`/models/` excluded). Prefetched by **`scripts/setup_aiavt.sh`** → `scripts/download_assets.py`, or on **first `main.py` run**. |
| **Avatar zips / `./data/...`** | Same: **prefetch** or **first run** (Hugging Face). |

## One-time prerequisites (Mac)

- SSH key registered on Vast for the instance.
- From the instance page, note **`SSH host`** and **`port`** (direct IP often works better than the proxy).

## A — First-time GPU setup

### 1) Push code and create conda env + downloads + optional Ollama

From your Mac:

```bash
cd /path/to/AIAvatar
export VAST_HOST=<instance-ip-or-hostname>
export VAST_PORT=<ssh-port>

# Creates/updates aiavt env, pip deps, prefetches wav2lip.pth + avatars from Hugging Face.
./start_vast.sh --bootstrap
```

`--bootstrap` runs `./scripts/setup_aiavt.sh` on the remote **only if** the `aiavt` env is missing.

**Heavy downloads:** prefetch pulls **wav2lip.pth** plus **all** avatars listed under `DOWNLOAD.AVATARS` in `config.yml` (hundreds of MB total). To fetch **only** the checkpoint:

```bash
# On Vast shell after SSH:
cd /root/AIAvatar   # or your REMOTE_DIR
export PATH="$HOME/.local/bin:$PATH"
PREFETCH_ASSETS_EXTRA='--models-only' ./scripts/setup_aiavt.sh
```

To skip prefetch entirely (downloads happen when you first run `main.py`):

```bash
PREFETCH_ASSETS=0 ./scripts/setup_aiavt.sh
```

### 2) Install Ollama on the GPU (chat / LLM)

`setup_aiavt.sh` **does not** install Ollama on Linux unless you opt in:

```bash
INSTALL_OLLAMA_LINUX_AUTO=1 ./scripts/setup_aiavt.sh
# or manually:
curl -fsSL https://ollama.com/install.sh | sh
```

Then pull the model named in **`LLM_MODEL_NAME`** (default `llama3.2`):

```bash
ollama pull llama3.2
```

Ensure **`ollama serve`** is running (often auto-started by the installer).

### 3) Daily dev loop (Mac)

```bash
export VAST_HOST=... VAST_PORT=...
./start_vast.sh
```

This **rsyncs** (with root-anchored excludes so **`src/wav2lip/models/`** is included), starts **`run.sh`** on the GPU under **`nohup`**, and opens an **`ssh -f -N`** tunnel **`localhost:8010 → GPU:8010`**.

Open: **`http://127.0.0.1:8010/index.html`**

---

## B — Smoke tests (after server claims it’s listening)

On **Mac** (tunnel must be up):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8010/
```

On **GPU** (SSH):

```bash
# Logs from start_vast / nohup
tail -50 /tmp/aiavatar-run.log

# CUDA available to PyTorch
export PATH="$HOME/.local/bin:$PATH"
micromamba run -n aiavt python -c "import torch; print('cuda:', torch.cuda.is_available())"

# Ollama up (same box as app)
curl -s http://127.0.0.1:11434/api/tags | head -c 200 && echo
```

---

## C — Troubleshooting

| Symptom | Likely fix |
|--------|------------|
| `ModuleNotFoundError: src.wav2lip.models` | Old rsync excluded every `models/` path. Ensure excludes use **`/models/`** only at repo root; re-rsync. |
| `curl` → **000** | Process crashed before bind; read **`/tmp/aiavatar-run.log`**. |
| Env “missing” but **`/venv/aiavt`** exists | **`start_vast.sh`** detects **`micromamba run -n aiavt`** or **`/venv/aiavt/bin/python`**. Update **`start_vast.sh`** from repo if needed. |
| LLM errors | Install/start **Ollama** on GPU; **`ollama pull`** model matching **`config.yml`**. |
| **`rsync` prints usage** | Don’t put **`#` comments** inside `\`-continued **`rsync`** lines in shell scripts. |

---

## D — Environment variables reference

| Variable | Role |
|---------|------|
| `VAST_HOST`, `VAST_PORT` | SSH target for **`start_vast.sh`** |
| `PREFETCH_ASSETS` | **`1`** (default): run **`download_assets.py`** after pip in **`setup_aiavt.sh`** |
| `PREFETCH_ASSETS_EXTRA` | e.g. **`--models-only`** |
| `INSTALL_OLLAMA_LINUX_AUTO` | **`1`**: run Ollama **`install.sh`** on Linux during setup |
| `SKIP_RSYNC`, `REMOTE_AUTO_SETUP` / **`--bootstrap`** | See **`start_vast.sh`** header comments |
