#!/bin/bash
set -euo pipefail

##############################################
#        Persistent setup on Vast.ai Volume  #
##############################################

# === где смонтирован том (volume) ===
VOLUME_DIR="${VOLUME_DIR:-/data}"               # путь монтирования volume в контейнере
COMFYUI_DIR="${COMFYUI_DIR:-$VOLUME_DIR/ComfyUI}"

# === рабочее пространство (для совместимости с чужими скриптами/образами) ===
WORKSPACE="${WORKSPACE:-/workspace}"
mkdir -p "$WORKSPACE" "$COMFYUI_DIR"

# === виртуальное окружение Python на томе ===
VENV_DIR="${VENV_DIR:-$VOLUME_DIR/venv/main}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# === кэши на томе ===
export HF_HOME="$VOLUME_DIR/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
export DIFFUSERS_CACHE="$HF_HOME/diffusers"
export PIP_CACHE_DIR="$VOLUME_DIR/.cache/pip"
export XDG_CACHE_HOME="$VOLUME_DIR/.cache"
mkdir -p "$HF_HOME" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME"

# === линк на случай, если что-то ожидает $WORKSPACE/ComfyUI ===
ln -sfn "$COMFYUI_DIR" "$WORKSPACE/ComfyUI"
ln -sfn "$COMFYUI_DIR" "$HOME/ComfyUI" 2>/dev/null || true

# === apt helper (если доступен) ===
APT_INSTALL='apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y'
AUTO_UPDATE="${AUTO_UPDATE:-true}"

# ——————————————————————————————————————————————
# Конфигурация загрузок/пакетов
# ——————————————————————————————————————————————

APT_PACKAGES=(
    # "git-lfs"
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

### ====== Логика провижининга (адаптирована под volume и venv) ======

function ensure_base_tools() {
    if command -v apt-get >/dev/null 2>&1; then
        missing=()
        command -v git     >/dev/null 2>&1 || missing+=("git")
        command -v wget    >/dev/null 2>&1 || missing+=("wget")
        command -v python3 >/dev/null 2>&1 || missing+=("python3")
        command -v pip3    >/dev/null 2>&1 || missing+=("python3-pip")
        python3 -m venv --help >/dev/null 2>&1 || missing+=("python3-venv")
        if (( ${#missing[@]} > 0 )); then
            eval "$APT_INSTALL ${missing[*]}"
        fi
    else
        echo "apt-get недоступен — пропускаю установку базовых пакетов. Убедись, что git/wget/python3/pip установлены."
    fi
}

function ensure_venv() {
    if [[ ! -d "$VENV_DIR" ]]; then
        mkdir -p "$(dirname "$VENV_DIR")"
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    fi

    # Создаём симлинк /venv/main -> $VENV_DIR (для совместимости с чужими стартерами)
    mkdir -p /venv || true
    ln -sfn "$VENV_DIR" /venv/main

    # Абсолютные интерпретатор/пип из venv
    export PY="$VENV_DIR/bin/python"
    export PIP="$VENV_DIR/bin/pip"

    # Активируем venv и обновляем pip
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    "$PY" -m pip install --upgrade pip
    "$PIP" config set global.cache-dir "$PIP_CACHE_DIR" >/dev/null 2>&1 || true

    # Приоритет venv в PATH
    export PATH="$VENV_DIR/bin:$PATH"
}

function provisioning_start() {
    provisioning_print_header
    ensure_base_tools
    ensure_venv
    provisioning_get_apt_packages
    provisioning_get_pip_packages
    provisioning_get_nodes

    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints"       "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/unet"              "${UNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models"  "${DIFFUSION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/loras"             "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/controlnet"        "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae"               "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"     "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/esrgan"            "${ESRGAN_MODELS[@]}"

    provisioning_get_workflows "${COMFYUI_DIR}/input/workflows"      "${WORKFLOWS[@]}"
    provisioning_get_files     "${COMFYUI_DIR}/input"                 "${INPUT_IMAGES[@]}"

    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            eval "$APT_INSTALL ${APT_PACKAGES[*]}"
        else
            echo "apt-get недоступен, пропускаю установку APT_PACKAGES"
        fi
    fi
}

function provisioning_get_workflows() {
    if [[ -z ${2:-} ]]; then return 1; fi
    local dir="$1"; shift
    local arr=("$@")
    mkdir -p "$dir"
    printf "Downloading %s workflow(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading workflow: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        "$PIP" install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        local dir="${repo##*/}"
        local path="${COMFYUI_DIR}/custom_nodes/${dir}"
        local requirements="${path}/requirements.txt"
        mkdir -p "${COMFYUI_DIR}/custom_nodes"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                    "$PIP" install --no-cache-dir -r "$requirements"
                fi
            fi
        else
            printf "Cloning node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                "$PIP" install --no-cache-dir -r "$requirements"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z ${2:-} ]]; then return 1; fi
    local dir="$1"; shift
    local arr=("$@")
    mkdir -p "$dir"
    printf "Downloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "${HF_TOKEN:-}" ]] || return 1
    local url="https://huggingface.co/api/whoami-v2"
    local response
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

function provisioning_has_valid_civitai_token() {
    [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
    local url="https://civitai.com/api/v1/models?hidden=1&limit=1"
    local response
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

# Скачать из $1 (URL) в каталог $2
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
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="$dots" -P "$outdir" "$url"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="$dots" -P "$outdir" "$url"
    fi
}

# ===== Запуск провижининга (можно отключить, создав /.noprovisioning) =====
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
