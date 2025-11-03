#!/bin/bash
set -euo pipefail

##############################################
#        ComfyUI provisioning for Vast       #
#     Volume mounted at /data (immutable)    #
##############################################

# ---- Configuration ----
DATA="${DATA:-/data}"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-$DATA/ComfyUI}"
VENV_DIR="${VENV_DIR:-/venv/main}"

# Activate venv
if [[ ! -d "$VENV_DIR" ]]; then
  VENV_DIR="$DATA/venv/main"
  mkdir -p "$(dirname "$VENV_DIR")"
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

PY="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# ---- Cache directories ----
export HF_HOME="$DATA/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"
export PIP_CACHE_DIR="$DATA/.cache/pip"
export XDG_CACHE_HOME="$DATA/.cache"
export MPLCONFIGDIR="$DATA/.cache/matplotlib"

mkdir -p "$HF_HOME" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE" \
         "$PIP_CACHE_DIR" "$XDG_CACHE_HOME" "$MPLCONFIGDIR"
mkdir -p "$COMFYUI_DIR"/{models,custom_nodes,input,output} "$WORKSPACE"

# ---- Symlinks for compatibility ----
ln -sfn "$COMFYUI_DIR" "$WORKSPACE/ComfyUI"
ln -sfn "$COMFYUI_DIR" "$HOME/ComfyUI" 2>/dev/null || true

# ---- Configuration Variables ----
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Arrays for optional downloads (customize as needed)
NODES=()
CHECKPOINT_MODELS=()
LORA_MODELS=()
VAE_MODELS=()

# ---- Helper Functions ----

log_info() {
  printf "[INFO] %s\n" "$*"
}

log_warn() {
  printf "[WARN] %s\n" "$*" >&2
}

log_error() {
  printf "[ERROR] %s\n" "$*" >&2
}

apt_install_if_missing() {
  command -v apt-get >/dev/null 2>&1 || return 0
  local need_sudo=""
  command -v sudo >/dev/null 2>&1 && need_sudo="sudo"
  local need_update=0

  for pair in "$@"; do
    local check="${pair%%:*}"
    local pkg="${pair##*:}"
    if ! command -v "$check" >/dev/null 2>&1; then
      if [[ $need_update -eq 0 ]]; then
        log_info "Running apt-get update..."
        $need_sudo apt-get update -y >/dev/null 2>&1 || true
        need_update=1
      fi
      log_info "Installing: $pkg"
      DEBIAN_FRONTEND=noninteractive $need_sudo apt-get install -y "$pkg" >/dev/null 2>&1 || \
        log_warn "Failed to install $pkg"
    fi
  done
}

pip_install_if_missing() {
  for pair in "$@"; do
    local imp="${pair%%:*}"
    local pkg="${pair##*:}" 
    if ! "$PY" -c "import ${imp}" 2>/dev/null; then
      log_info "Installing: $pkg"
      "$PIP" install --no-cache-dir "$pkg" 2>&1 | grep -E "(Successfully|ERROR)" || true
    fi
  done
}

# ---- Main Provisioning ----

ensure_base_tools() {
  log_info "Checking base tools..."
  apt_install_if_missing \
    "git:git" \
    "wget:wget" \
    "rsync:rsync" \
    "ffmpeg:ffmpeg"
}

install_pip_packages() {
  log_info "Installing Python packages..."
  "$PY" -m pip install --upgrade pip --quiet 2>/dev/null || true

  # Core ML libraries
  pip_install_if_missing \
    "diffusers" \
    "accelerate" \
    "peft" \
    "transformers" \
    "numpy" \
    "torch"  # Should already be installed

  # Image/Video processing
  pip_install_if_missing \
    "PIL:pillow" \
    "matplotlib" \
    "imageio" \
    "imageio_ffmpeg:imageio-ffmpeg" \
    "scipy" \
    "skimage:scikit-image" \
    "cv2:opencv-contrib-python-headless"

  # ComfyUI-specific dependencies
  pip_install_if_missing \
    "piexif" \
    "blend_modes" \
    "moviepy" \
    "soundfile" \
    "segment_anything"

  log_info "Verifying critical imports..."
  "$PY" << 'VERIFY_PY'
import sys
failed = []
for mod in ("diffusers", "cv2", "PIL", "scipy", "numpy", "torch"):
    try:
        __import__(mod)
    except ImportError as e:
        failed.append(f"{mod}: {e}")
if failed:
    print("[WARN] Some imports failed:", file=sys.stderr)
    for f in failed:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)
VERIFY_PY
}

install_nodes() {
  log_info "Setting up custom nodes..."
  
  # Install key nodes
  local nodes_to_install=(
    "https://github.com/continue-revolution/ComfyUI-SAM2"
  )

  for repo in "${nodes_to_install[@]}"; do
    local dir="${repo##*/}"
    local path="$COMFYUI_DIR/custom_nodes/$dir"
    if [[ ! -d "$path/.git" ]]; then
      log_info "Cloning: $repo"
      git clone --recursive "$repo" "$path" 2>&1 | tail -1
      [[ -f "$path/requirements.txt" ]] && \
        "$PIP" install --no-cache-dir -r "$path/requirements.txt" 2>&1 | tail -1
    fi
  done

  # Clean up invalid custom nodes
  rm -rf "$COMFYUI_DIR/custom_nodes/sam2" 2>/dev/null || true
}

main() {
  printf "\n%s\n" "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
  printf "%s\n" "    ComfyUI Provisioning for Vast AI"
  printf "%s\n" "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"

  ensure_base_tools
  install_pip_packages
  install_nodes

  printf "\n%s\n\n" "✓ Provisioning complete!"
}

# Run if not disabled
[[ ! -f /.noprovisioning ]] && main || log_info "Provisioning disabled (/.noprovisioning exists)"
