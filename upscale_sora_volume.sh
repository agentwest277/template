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
mkdir -p "$HF_HOME" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME"

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

APT_PACKAGES=(
  # добавьте при необходимости, напр. "git-lfs"
)

PIP_PACKAGES=(
  "diffusers"
  "peft"
  "accelerate"
  "transformers"
)

NODES=(
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/smthemex/ComfyUI_DiffuEraser"
  "https://github.com/yolain/ComfyUI-Easy-Use"
  "https://github.com/kijai/ComfyUI-KJNodes"
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/lihaoyun6/ComfyUI-FlashVSR_Ultra_Fast"
  "https://github.com/facebookresearch/sam2"
  "https://github.com/ltdrdata/was-node-suite-comfyui"
  "https://github.com/rgthree/rgthree-comfy"
  "https://github.com/chflame163/ComfyUI_LayerStyle"
  "https://github.com/ltdrdata/ComfyUI-Impact-Pack"
)

INPUT_IMAGES=()

TEXT_ENCODER_MODELS=()

WORKFLOWS=()

CHECKPOINT_MODELS=(
  "https://huggingface.co/alexgenovese/checkpoint/resolve/5d96d799d7e943878a2c7614674eb48435891d00/realisticVisionV60B1_v60B1VAE.safetensors"
)

DIFFUSION_MODELS=()
UNET_MODELS=()

LORA_MODELS=(
  "https://huggingface.co/wangfuyun/PCM_Weights/resolve/main/sd15/pcm_sd15_smallcfg_2step_converted.safetensors"
)

VAE_MODELS=()
ESRGAN_MODELS=()
CONTROLNET_MODELS=()

# ---- Функции ----

function provisioning_print_header() {
  printf "\n##############################################\n#          Provisioning container            #\n##############################################\n\n"
}

function provisioning_print_end() {
  printf "\nProvisioning complete: Application will start now\n\n"
}

function ensure_base_tools() {
  local need_sudo=""
  if command -v sudo >/dev/null 2>&1; then need_sudo="sudo"; fi

  if command -v apt-get >/dev/null 2>&1; then
    # проверим стандартные утилиты
    local missing=()
    command -v git     >/dev/null 2>&1 || missing+=("git")
    command -v wget    >/dev/null 2>&1 || missing+=("wget")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v rsync   >/dev/null 2>&1 || missing+=("rsync")
    if (( ${#missing[@]} > 0 )); then
      $need_sudo apt-get update -y
      DEBIAN_FRONTEND=noninteractive $need_sudo apt-get install -y "${missing[@]}"
    fi
    if (( ${#APT_PACKAGES[@]} > 0 )); then
      $need_sudo apt-get update -y
      DEBIAN_FRONTEND=noninteractive $need_sudo apt-get install -y "${APT_PACKAGES[@]}"
    fi
  else
    echo "apt-get недоступен — пропускаю установку APT пакетов."
  fi
}

function provisioning_get_pip_packages() {
  if (( ${#PIP_PACKAGES[@]} > 0 )); then
    "$PY" -m pip install --upgrade pip
    "$PIP" install --no-cache-dir "${PIP_PACKAGES[@]}"
  fi
}

function provisioning_get_nodes() {
  mkdir -p "${COMFYUI_DIR}/custom_nodes"
  for repo in "${NODES[@]}"; do
    local dir="${repo##*/}"
    local path="${COMFYUI_DIR}/custom_nodes/${dir}"
    local requirements="${path}/requirements.txt"

    if [[ -d $path ]]; then
      if [[ ${AUTO_UPDATE,,} != "false" ]]; then
        printf "Updating node: %s...\n" "$repo"
        ( cd "$path" && git pull --ff-only || true )
        [[ -f "$requirements" ]] && "$PIP" install --no-cache-dir -r "$requirements" || true
      fi
    else
      printf "Cloning node: %s...\n" "$repo"
      git clone --recursive "$repo" "$path" || true
      [[ -f "$requirements" ]] && "$PIP" install --no-cache-dir -r "$requirements" || true
    fi
  done
}

function provisioning_get_files() {
  # $1 = target dir, остальные — URL
  if [[ $# -lt 2 ]]; then return 0; fi
  local dir="$1"; shift
  local arr=( "$@" )
  mkdir -p "$dir"
  printf "Downloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Downloading: %s\n" "$url"
    provisioning_download "$url" "$dir" || true
  done
}

function provisioning_get_workflows() {
  if [[ $# -lt 2 ]]; then return 0; fi
  local dir="$1"; shift
  local arr=( "$@" )
  mkdir -p "$dir"
  printf "Downloading %s workflow(s) to %s...\n" "${#arr[@]}" "$dir"
  for url in "${arr[@]}"; do
    printf "Downloading workflow: %s\n" "$url"
    provisioning_download "$url" "$dir" || true
  done
}

function provisioning_has_valid_hf_token() {
  [[ -n "${HF_TOKEN:-}" ]] || return 1
  local url="https://huggingface.co/api/whoami-v2"
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" -H "Authorization: Bearer $HF_TOKEN" "$url" || echo 000)
  [[ "$code" == "200" ]]
}

function provisioning_has_valid_civitai_token() {
  [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
  local url="https://civitai.com/api/v1/models?hidden=1&limit=1"
  local code
  code=$(curl -o /dev/null -s -w "%{http_code}" -H "Authorization: Bearer $CIVITAI_TOKEN" "$url" || echo 000)
  [[ "$code" == "200" ]]
}

# Скачать из $1(URL) в каталог $2
function provisioning_download() {
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

function provisioning_start() {
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

# Позволяем отключить провижининг созданием файла /.noprovisioning
if [[ ! -f /.noprovisioning ]]; then
  provisioning_start
fi
