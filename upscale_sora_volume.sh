#!/bin/bash
set -euo pipefail

##############################################
#        ComfyUI provisioning for Vast       #
#     Volume mounted at /data (immutable)    #
##############################################

# ---- Базовые пути/переменные ----
DATA="${DATA:-/data}"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-$DATA/ComfyUI}"

# venv: используем существующий /venv/main, иначе создаём на томе
VENV_DIR="${VENV_DIR:-/venv/main}"
if [[ ! -d "$VENV_DIR" ]]; then
  VENV_DIR="$DATA/venv/main"
  mkdir -p "$(dirname "$VENV_DIR")"
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

PY="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# Кэши на томе
export HF_HOME="$DATA/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"
export PIP_CACHE_DIR="$DATA/.cache/pip"
export XDG_CACHE_HOME="$DATA/.cache"
export MPLCONFIGDIR="$DATA/.cache/matplotlib"
mkdir -p "$HF_HOME" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME" "$MPLCONFIGDIR"

# Готовим каталоги
mkdir -p "$COMFYUI_DIR"/{models,custom_nodes,input,output} "$WORKSPACE"

# Если /workspace/ComfyUI — реальная папка, аккуратно перенесём данные на том
if [[ -d "$WORKSPACE/ComfyUI" && ! -L "$WORKSPACE/ComfyUI" ]]; then
  rsync -a --remove-source-files "$WORKSPACE/ComfyUI/" "$COMFYUI_DIR/" || true
  rm -rf "$WORKSPACE/ComfyUI"
fi

# Симлинки для совместимости
ln -sfn "$COMFYUI_DIR" "$WORKSPACE/ComfyUI"
ln -sfn "$COMFYUI_DIR" "$HOME/ComfyUI" 2>/dev/null || true

# ---- Настройки установки ----
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Заполняй по желанию:
NODES=()
INPUT_IMAGES=()
TEXT_ENCODER_MODELS=()
WORKFLOWS=()
CHECKPOINT_MODELS=()
DIFFUSION_MODELS=()
UNET_MODELS=()
LORA_MODELS=()
VAE_MODELS=()
ESRGAN_MODELS=()
CONTROLNET_MODELS=()

# ── ХЕЛПЕРЫ ───────────────────────────────────────────────────────────────────

apt_install_if_missing() {
  command -v apt-get >/dev/null 2>&1 || { echo "apt-get недоступен"; return 0; }
  local need_sudo=""
  command -v sudo >/dev/null 2>&1 && need_sudo="sudo"
  local need_update=0
  
  for pair in "$@"; do
    local check="${pair%%:*}"
    local pkg="${pair##*:}"
    if ! command -v "$check" >/dev/null 2>&1; then
      if [[ $need_update -eq 0 ]]; then
        $need_sudo apt-get update -y
        need_update=1
      fi
      DEBIAN_FRONTEND=noninteractive $need_sudo apt-get install -y "$pkg"
    fi
  done
}

pip_install_if_missing() {
  for pair in "$@"; do
    local imp="${pair%%:*}"
    local pkg
    if [[ "$pair" == "$imp" ]]; then
      pkg="$imp"
    else
      pkg="${pair#*:}"
    fi
    # Проверяем импорт; если падает — ставим пакет
    "$PY" - "$imp" >/dev/null 2>&1 <<'PYCODE' || "$PIP" install --no-cache-dir "$pkg" || true
import importlib, sys
mod = sys.argv[1]
try:
    importlib.import_module(mod)
except Exception:
    raise SystemExit(1)
PYCODE
  done
}

pip_requirements_minimal() {
  local reqfile="$1"
  [[ -f "$reqfile" ]] || return 0
  "$PIP" install --no-cache-dir -r "$reqfile" || true
}

# ── ЛОГИКА УСТАНОВКИ ──────────────────────────────────────────────────────────

provisioning_print_header() {
  printf "\n##############################################\n#          Provisioning container            #\n##############################################\n\n"
}

provisioning_print_end() {
  printf "\nProvisioning complete: Application will start now\n\n"
}

ensure_base_tools() {
  apt_install_if_missing \
    "git:git" \
    "wget:wget" \
    "rsync:rsync" \
    "ffmpeg:ffmpeg"
}

provisioning_get_pip_packages() {
  "$PY" -m pip install --upgrade pip || true

  # Библиотеки, на которые ругались ноды
  pip_install_if_missing \
    "diffusers" \
    "accelerate" \
    "peft" \
    "transformers" \
    "matplotlib" \
    "imageio" \
    "imageio_ffmpeg:imageio-ffmpeg" \
    "scipy" \
    "skimage:scikit-image" \
    "piexif" \
    "blend_modes" \
    "moviepy" \
    "soundfile" \
    "segment_anything"

  # OpenCV contrib
  "$PIP" uninstall -y opencv-python opencv-python-headless >/dev/null 2>&1 || true
  pip_install_if_missing "cv2:opencv-contrib-python-headless"

  # Лёгкий прогрев импорта
  "$PY" - <<'PY'
import importlib
for m in ("diffusers","imageio","imageio_ffmpeg","scipy","skimage","piexif","blend_modes","segment_anything","cv2"):
    try:
        importlib.import_module(m)
    except Exception as e:
        print(f"[WARN] import {m} failed: {e}")
PY
}

provisioning_get_nodes() {
  mkdir -p "${COMFYUI_DIR}/custom_nodes"
  for repo in "${NODES[@]}"; do
    local dir="${repo##*/}"
    local path="${COMFYUI_DIR}/custom_nodes/${dir}"
    local requirements="${path}/requirements.txt"

    if [[ -d "$path/.git" ]]; then
      if [[ ${AUTO_UPDATE,,} != "false" ]]; then
        printf "Updating node: %s...\n" "$repo"
        ( cd "$path" && git pull --ff-only || true )
      else
        printf "Node exists (skip update): %s\n" "$repo"
      fi
    else
      printf "Cloning node: %s...\n" "$repo"
      git clone --recursive "$repo" "$path" || true
    fi

    [[ -f "$requirements" ]] && pip_requirements_minimal "$requirements" || true
  done

  # SAM2: чистим пустую папку
  local sam2_dir="${COMFYUI_DIR}/custom_nodes/sam2"
  local comfy_sam2_dir="${COMFYUI_DIR}/custom_nodes/ComfyUI-SAM2"

  if [[ -d "$sam2_dir" && ! -f "$sam2_dir/__init__.py" ]]; then
    echo "[INFO] Removing invalid custom_nodes/sam2 (not a valid Comfy node)."
    rm -rf "$sam2_dir"
  fi

  if [[ ! -d "$comfy_sam2_dir/.git" ]]; then
    echo "[INFO] Installing ComfyUI-SAM2 node..."
    git clone --recursive https://github.com/continue-revolution/ComfyUI-SAM2 "$comfy_sam2_dir" || true
    [[ -f "$comfy_sam2_dir/requirements.txt" ]] && pip_requirements_minimal "$comfy_sam2_dir/requirements.txt"
  else
    echo "[INFO] Updating ComfyUI-SAM2 node..."
    ( cd "$comfy_sam2_dir" && git pull --ff-only || true )
    [[ -f "$comfy_sam2_dir/requirements.txt" ]] && pip_requirements_minimal "$comfy_sam2_dir/requirements.txt"
  fi
}

provisioning_get_files() {
  if [[ $# -lt 2 ]]; then return 0; fi
  local dir="$1"
  shift
  local arr=("$@")
  mkdir -p "$dir"
  printf "Downloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Downloading: %s\n" "$url"
    provisioning_download "$url" "$dir" || true
  done
}

provisioning_get_workflows() {
  if [[ $# -lt 2 ]]; then return 0; fi
  local dir="$1"
  shift
  local arr=("$@")
  mkdir -p "$dir"
  printf "Downloading %s workflow(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Downloading workflow: %s\n" "$url"
    provisioning_download "$url" "$dir" || true
  done
}

provisioning_has_valid_hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] || return 1
  local url="https://huggingface.co/api/whoami-v2"
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" -H "Authorization: Bearer $HF_TOKEN" "$url" || echo 000)
  [[ "$code" == "200" ]]
}

provisioning_has_valid_civitai_token() {
  [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
  local url="https://civitai.com/api/v1/models?hidden=1&limit=1"
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" "$url" || echo 000)
  [[ "$code" == "200" ]]
}

# Основная функция скачивания
provisioning_download() {
  local url="$1"
  local outdir="$2"
  local dots="${3:-4M}"
  local auth_token=""

  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="$HF_TOKEN"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+
