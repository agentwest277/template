#!/usr/bin/env bash
set -euo pipefail

##############################################
#      ComfyUI provisioning for Vast         #
#    Volume mounted at /data (immutable)     #
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
mkdir -p "$COMFYUI_DIR"/{models,custom_nodes,input,output} "$WORKSPACE" "$DATA/output" "$DATA/script"

# Если /workspace/ComfyUI — реальная папка, аккуратно перенесём данные на том
if [[ -d "$WORKSPACE/ComfyUI" && ! -L "$WORKSPACE/ComfyUI" ]]; then
  rsync -a --remove-source-files "$WORKSPACE/ComfyUI/" "$COMFYUI_DIR/" || true
  rm -rf "$WORKSPACE/ComfyUI"
fi

# Симлинки для совместимости со скриптами/образами
ln -sfn "$COMFYUI_DIR" "$WORKSPACE/ComfyUI"
ln -sfn "$COMFYUI_DIR" "$HOME/ComfyUI" 2>/dev/null || true

# ---- Настройки установки (оставляем как было; наполняй по необходимости) ----
AUTO_UPDATE="${AUTO_UPDATE:-true}"

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

# ── ХЕЛПЕРЫ УСТАНОВКИ ────────────────────────────────────────────────────────

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

  # OpenCV contrib — нужен guidedFilter (cv2.ximgproc) для LayerStyle
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

# ── ЗАПУСК COMFY + WATCHER (без systemd) ─────────────────────────────────────

is_port_free() { ! ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$1$"; }

pick_comfy_port() {
  [[ -n "${COMFY_PORT:-}" ]] && { echo "$COMFY_PORT"; return; }
  if is_port_free 18188; then echo 18188; return; fi
  if is_port_free 8188;  then echo 8188;  return; fi
  # если оба заняты — найдём свободный от 20000
  for p in $(seq 20000 20100); do is_port_free "$p" && { echo "$p"; return; }; done
  echo 18188
}

wait_http_up() {
  local url="$1" ; local end=$((SECONDS+600))
  while (( SECONDS < end )); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" || echo 000)
    [[ "$code" != "000" && "$code" -lt 500 ]] && return 0
    sleep 2
  done
  return 1
}

start_comfy() {
  local port
  port=$(pick_comfy_port)
  export COMFY_URL="http://127.0.0.1:${port}"
  echo "[start] COMFY_URL=$COMFY_URL"

  # если уже слушает — не стартуем заново
  if wait_http_up "${COMFY_URL%/}/system_stats"; then
    echo "[start] ComfyUI уже запущен на $COMFY_URL"
    return 0
  fi

  # ищем entrypoint
  local entry="$COMFYUI_DIR/main.py"
  if [[ ! -f "$entry" && -f "$WORKSPACE/ComfyUI/main.py" ]]; then
    entry="$WORKSPACE/ComfyUI/main.py"
  fi
  if [[ ! -f "$entry" ]]; then
    echo "[ERR] Не найден ComfyUI main.py в $COMFYUI_DIR или $WORKSPACE/ComfyUI"
    return 1
  fi

  # лог
  local logf="$DATA/output/comfy.nohup.log"
  touch "$logf"

  # стартуем
  echo "[start] Запуск ComfyUI на 0.0.0.0:${port} (лог: $logf)"
  nohup "$PY " -u "$entry" --listen 0.0.0.0 --port "$port" >>"$logf" 2>&1 &

  # ждём доступности
  if wait_http_up "${COMFY_URL%/}/system_stats"; then
    echo "[start] ComfyUI доступен: $COMFY_URL"
    return 0
  else
    echo "[ERR] ComfyUI не поднялся вовремя"
    return 1
  fi
}

start_watcher_if_exists() {
  local watcher="$DATA/script/generate-watch.sh"
  if [[ ! -x "$watcher" ]]; then
    echo "[watch] $watcher не найден (или не исполняем). Пропуск автозапуска."
    echo "[hint] Скопируй свой watcher в /data/script/generate-watch.sh и сделай chmod +x"
    return 0
  fi

  # уже запущен?
  if pgrep -f "$watcher" >/dev/null 2>&1; then
    echo "[watch] watcher уже запущен"
    return 0
  fi

  echo "[watch] стартую watcher…"
  # передаём COMFY_URL в окружение
  COMFY_URL="$COMFY_URL" nohup "$watcher" >>"$DATA/output/watch.nohup.log" 2>&1 &
  echo "[watch] tail -f $DATA/output/watch.nohup.log"
}

install_cron_autostart() {
  # автозапуск watcher при перезапуске контейнера (если cron доступен)
  command -v crontab >/dev/null 2>&1 || return 0
  local watcher="$DATA/script/generate-watch.sh"
  [[ -x "$watcher" ]] || return 0

  # добавим @reboot, если нет
  local line="@reboot COMFY_URL=$COMFY_URL $watcher >>$DATA/output/watch.nohup.log 2>&1"
  (crontab -l 2>/dev/null | grep -Fv "$watcher" || true; echo "$line") | crontab -
  echo "[cron] @reboot автозапуск watcher установлен"
}

# ── ЗАПУСК ────────────────────────────────────────────────────────────────────

# 1) (опционально) провижининг (можно отключить /.noprovisioning)
if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi

# 2) стартуем Comfy
start_comfy || true

# 3) автозапуск вотчера, если он лежит в /data/script/generate-watch.sh
start_watcher_if_exists || true

# 4) сделать автозапуск вотчера через cron (@reboot), если cron есть
install_cron_autostart || true

echo "[done] on-start завершён. Логи: $DATA/output/comfy.nohup.log и $DATA/output/watch.nohup.log"
