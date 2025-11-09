#!/bin/bash
set -euo pipefail

##############################################
#        ComfyUI provisioning for Vast       #
#     Volume mounted at /data (immutable)    #
##############################################

# ---- Базовые пути/переменные ----
DATA="${DATA:-/data}"                        # точка монтирования volume на Vast
WORKSPACE="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${COMFYUI_DIR:-$DATA/ComfyUI}"  # корень ComfyUI на томе

# venv: используем существующий /venv/main, иначе создаём на томе
VENV_DIR="${VENV_DIR:-/venv/main}"
if [[ ! -d "$VENV_DIR" ]]; then
  VENV_DIR="$DATA/venv/main"
  mkdir -p "$(dirname "$VENV_DIR")"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

PY="$VENV_DIR/bin/python"
PIP="$VENV_DIR/bin/pip"

# Кэши на томе, чтобы всё тяжёлое копилось в /data
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

# Симлинки для совместимости со скриптами/образами
ln -sfn "$COMFYUI_DIR" "$WORKSPACE/ComfyUI"
ln -sfn "$COMFYUI_DIR" "$HOME/ComfyUI" 2>/dev/null || true

# ---- Настройки установки ----
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Заполняй по желанию (модели не скачаются повторно, если уже лежат на volume):
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
  # аргументы — пары "cmd:pkg"
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

# аргументы — строки "import_name[:pip_pkg]"
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

  # Библиотеки для узлов (VHS/LayerStyle/SAM2 и т.п.)
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
    "segment_anything:segment-anything"

  "$PIP" uninstall -y opencv-python opencv-python-headless >/dev/null 2>&1 || true
  pip_install_if_missing "cv2:opencv-contrib-python-headless"

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

  # SAM2: чиним «левую» папку sam2 без __init__.py
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
  # $1 = target dir, остальные — URL
  if [[ $# -lt 2 ]]; then return 0; fi
  local dir="$1"; shift
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
  local dir="$1"; shift
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

# Скачать из $1(URL) в каталог $2
provisioning_download() {
  local url="$1"
  local outdir="$2"
  local dots="${3:-4M}"
  local auth_token=""

  if [[ -n "${HF_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
    auth_token="$HF_TOKEN"
  elif [[ -n "${CIVITAI_TOKEN:-}" && $url =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
    auth_token="$CIVITAI_TOKEN"
  fi

  if [[ -n "$auth_token" ]]; then
    wget --header="Authorization: Bearer $auth_token" \
         -qnc --content-disposition --show-progress -e dotbytes="$dots" -P "$outdir" "$url"
  else
    wget -qnc --content-disposition --show-progress -e dotbytes="$dots" -P "$outdir" "$url"
  fi
}

provisioning_start() {
  provisioning_print_header
  ensure_base_tools
  provisioning_get_pip_packages
  provisioning_get_nodes

  provisioning_get_files "${COMFYUI_DIR}/models/checkpoints"      "${CHECKPOINT_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/unet"             "${UNET_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/loras"            "${LORA_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/controlnet"       "${CONTROLNET_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/vae"              "${VAE_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"    "${TEXT_ENCODER_MODELS[@]}"
  provisioning_get_files "${COMFYUI_DIR}/models/esrgan"           "${ESRGAN_MODELS[@]}"

  provisioning_get_workflows "${COMFYUI_DIR}/input/workflows"     "${WORKFLOWS[@]}"
  provisioning_get_files     "${COMFYUI_DIR}/input"               "${INPUT_IMAGES[@]}"

  provisioning_print_end
}

# ── АВТОЗАПУСК ГЕНЕРАЦИИ ─────────────────────────────────────────────────────

install_generate_autostart() {
  mkdir -p /usr/local/bin "$DATA/output"

  cat >/usr/local/bin/generate-watch.sh <<'SH'
#!/bin/bash
set -euo pipefail

DATA="${DATA:-/data}"
WORKSPACE="${WORKSPACE:-/workspace}"
PY="${PY:-/venv/main/bin/python}"
GEN_SCRIPT="${GEN_SCRIPT:-/data/script/my_generate.py}"
WORKFLOW="${WORKFLOW:-/data/script/workflow.json}"
OUTDIR="${OUTDIR:-/data/output}"
LOG="${LOG:-/data/output/watch.log}"

touch "$LOG"

# Ждём локальный ComfyUI (как в generate.py)
wait_comfy() {
  local url="${COMFY_URL:-http://127.0.0.1:8188}/system_stats"
  local end=$((SECONDS+600))
  while (( SECONDS < end )); do
    if curl -sSf --max-time 3 "$url" >/dev/null; then
      echo "[watch] ComfyUI is up" | tee -a "$LOG"
      return 0
    fi
    sleep 2
  done
  echo "[watch][ERR] ComfyUI is not up in time" | tee -a "$LOG"
  return 1
}

process_one() {
  local f="$1"
  local base="${f##*/}"
  local lock="$f.lock"
  local done="$f.done"

  # уже в работе или завершён
  [[ -e "$lock" || -e "$done" ]] && return 0

  # пропускаем пустые/неполные
  if [[ ! -s "$f" ]]; then
    return 0
  fi

  echo "[watch] start: $f" | tee -a "$LOG"
  : > "$lock"
  if "$PY" "$GEN_SCRIPT" --video "$f" --workflow-path "$WORKFLOW" --out "$OUTDIR" >>"$LOG" 2>&1; then
    echo "[watch] done: $f" | tee -a "$LOG"
    : > "$done"
  else
    echo "[watch][ERR] failed: $f" | tee -a "$LOG"
    rm -f "$lock"
    return 1
  fi
  rm -f "$lock"
  return 0
}

main_loop() {
  wait_comfy || true
  mkdir -p "$OUTDIR"
  while true; do
    shopt -s nullglob
    # Берём самый старый ещё не обработанный mp4
    mapfile -t files < <(find "$WORKSPACE" -maxdepth 1 -type f -name '*.mp4' -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
    for f in "${files[@]}"; do
      process_one "$f" || true
    done
    sleep 5
  done
}

main_loop
SH
  chmod +x /usr/local/bin/generate-watch.sh

  # systemd unit
  cat >/etc/systemd/system/generate-watch.service <<'UNIT'
[Unit]
Description=Watch /workspace for *.mp4 and run my_generate.py
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DATA=/data
Environment=WORKSPACE=/workspace
Environment=PY=/venv/main/bin/python
Environment=GEN_SCRIPT=/data/script/my_generate.py
Environment=WORKFLOW=/data/script/workflow.json
Environment=OUTDIR=/data/output
Environment=COMFY_URL=http://127.0.0.1:8188
ExecStart=/usr/local/bin/generate-watch.sh
Restart=always
RestartSec=3
Nice=5
# Логи в journald + /data/output/watch.log
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload || true
  systemctl enable generate-watch.service || true
  systemctl restart generate-watch.service || true

  echo "Autostart installed: systemctl status generate-watch.service"
}

# ── ЗАПУСК ────────────────────────────────────────────────────────────────────

# Позволяем отключить провижининг созданием файла /.noprovisioning
if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi

# Ставим автозапуск генерации (всегда)
install_generate_autostart
