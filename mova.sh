#!/bin/bash

source /venv/main/bin/activate
WORKSPACE=${WORKSPACE:-$HOME}
MOVA_DIR=${WORKSPACE}/MOVA
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# APT пакеты (если нужны дополнительные системные зависимости)
APT_PACKAGES=(
    "git"
    "wget"
    "curl"
)

# Python пакеты для MOVA
PIP_PACKAGES=(
    "torch>=2.1.0"
    "torchvision"
    "torchaudio"
    "transformers>=4.30.0"
    "diffusers>=0.27.0"
    "accelerate>=0.20.0"
    "safetensors"
    "pillow"
    "numpy"
    "einops"
    "omegaconf"
    "huggingface-hub"
    "sentencepiece"
    "protobuf"
)

# ComfyUI ноды (опциональные, для визуализации)
NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
)

# MOVA модели на HuggingFace
MOVA_MODELS=(
    "OpenMOSS-Team/MOVA-720p"  # ~56GB
    # "OpenMOSS-Team/MOVA-360p"  # Раскомментируйте если нужна 360p версия
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_install_mova
    provisioning_get_pip_packages
    provisioning_get_mova_models
    provisioning_create_launch_script
    provisioning_print_end
}

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#      Installing MOVA Video Generator       #\n"
    printf "#                                            #\n"
    printf "#         This will take some time           #\n"
    printf "#         (~56GB model download)             #\n"
    printf "#                                            #\n"
    printf "##############################################\n\n"
}

function provisioning_get_apt_packages() {
    if [[ -n ${APT_PACKAGES[@]} ]]; then
        printf "Installing APT packages...\n"
        sudo apt-get update
        sudo apt-get install -y ${APT_PACKAGES[@]}
    fi
}

function provisioning_install_mova() {
    printf "\n==================================\n"
    printf "Cloning MOVA repository...\n"
    printf "==================================\n"
    
    if [[ ! -d "$MOVA_DIR" ]]; then
        git clone https://github.com/OpenMOSS/MOVA.git "$MOVA_DIR"
        cd "$MOVA_DIR"
        printf "Installing MOVA package...\n"
        pip install -e .
    else
        printf "MOVA directory already exists. Updating...\n"
        cd "$MOVA_DIR"
        git pull
        pip install -e . --upgrade
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n ${PIP_PACKAGES[@]} ]]; then
        printf "\n==================================\n"
        printf "Installing Python packages...\n"
        printf "==================================\n"
        pip install --no-cache-dir ${PIP_PACKAGES[@]}
    fi
}

function provisioning_get_mova_models() {
    printf "\n==================================\n"
    printf "Downloading MOVA models...\n"
    printf "==================================\n"
    
    mkdir -p "${WORKSPACE}/models"
    
    for model in "${MOVA_MODELS[@]}"; do
        model_name="${model##*/}"
        model_path="${WORKSPACE}/models/${model_name}"
        
        printf "\nDownloading ${model}...\n"
        printf "This may take a while (model size: ~56GB)\n\n"
        
        if [[ -d "$model_path" ]]; then
            printf "Model ${model_name} already exists. Skipping...\n"
        else
            # Используем huggingface-cli для загрузки
            if command -v huggingface-cli &> /dev/null; then
                huggingface-cli download "${model}" --local-dir "${model_path}"
            else
                # Альтернативный метод через Python
                python3 << EOF
from huggingface_hub import snapshot_download
import os

print("Downloading ${model}...")
snapshot_download(
    repo_id="${model}",
    local_dir="${model_path}",
    local_dir_use_symlinks=False,
    resume_download=True
)
print("Download complete!")
EOF
            fi
        fi
    done
    
    printf "\n✓ All models downloaded successfully!\n"
}

function provisioning_create_launch_script() {
    printf "\n==================================\n"
    printf "Creating launch scripts...\n"
    printf "==================================\n"
    
    # Создание скрипта запуска
    cat > "${MOVA_DIR}/launch_mova.sh" << 'LAUNCH_EOF'
#!/bin/bash

# MOVA Launch Script
export CP_SIZE=2  # Context Parallel Size (количество GPU)
export CKPT_PATH=${WORKSPACE}/models/MOVA-720p/

# Активация окружения
source /venv/main/bin/activate

cd ${WORKSPACE}/MOVA

echo "=================================="
echo "MOVA Video Generator"
echo "=================================="
echo ""
echo "Model path: $CKPT_PATH"
echo "CP Size: $CP_SIZE"
echo ""
echo "Usage:"
echo "  torchrun --nproc_per_node=\$CP_SIZE scripts/inference_single.py \\"
echo "    --ckpt_path \$CKPT_PATH \\"
echo "    --cp_size \$CP_SIZE \\"
echo "    --height 720 \\"
echo "    --width 1280 \\"
echo "    --prompt 'Your video description with audio details' \\"
echo "    --ref_path './input_image.jpg' \\"
echo "    --output_path './output.mp4' \\"
echo "    --seed 42"
echo ""
echo "=================================="

# Пример запуска (раскомментируйте для автоматического запуска)
# torchrun \
#   --nproc_per_node=$CP_SIZE \
#   scripts/inference_single.py \
#   --ckpt_path $CKPT_PATH \
#   --cp_size $CP_SIZE \
#   --height 720 \
#   --width 1280 \
#   --prompt "A serene beach at sunset with waves crashing" \
#   --output_path "./output.mp4" \
#   --seed 42
LAUNCH_EOF

    chmod +x "${MOVA_DIR}/launch_mova.sh"
    
    # Создание Python скрипта для удобного запуска
    cat > "${MOVA_DIR}/generate_video.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
MOVA Video Generation Script
Simplified wrapper for MOVA inference
"""

import os
import subprocess
import argparse
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description='Generate video with MOVA')
    parser.add_argument('--prompt', type=str, required=True, 
                       help='Video and audio description prompt')
    parser.add_argument('--ref_path', type=str, default=None,
                       help='Reference image path (optional)')
    parser.add_argument('--output', type=str, default='./output.mp4',
                       help='Output video path')
    parser.add_argument('--height', type=int, default=720,
                       help='Video height')
    parser.add_argument('--width', type=int, default=1280,
                       help='Video width')
    parser.add_argument('--seed', type=int, default=42,
                       help='Random seed')
    parser.add_argument('--cp_size', type=int, default=2,
                       help='Context parallel size (number of GPUs)')
    parser.add_argument('--num_frames', type=int, default=193,
                       help='Number of frames to generate')
    parser.add_argument('--fps', type=int, default=24,
                       help='Frames per second')
    
    args = parser.parse_args()
    
    # Get model path
    workspace = os.environ.get('WORKSPACE', os.path.expanduser('~'))
    ckpt_path = os.path.join(workspace, 'models', 'MOVA-720p')
    
    if not os.path.exists(ckpt_path):
        print(f"Error: Model not found at {ckpt_path}")
        print("Please run install.sh first to download the model.")
        return
    
    # Build command
    cmd = [
        'torchrun',
        f'--nproc_per_node={args.cp_size}',
        'scripts/inference_single.py',
        '--ckpt_path', ckpt_path,
        '--cp_size', str(args.cp_size),
        '--height', str(args.height),
        '--width', str(args.width),
        '--num_frames', str(args.num_frames),
        '--fps', str(args.fps),
        '--prompt', args.prompt,
        '--output_path', args.output,
        '--seed', str(args.seed),
    ]
    
    if args.ref_path:
        cmd.extend(['--ref_path', args.ref_path])
    
    print("=" * 50)
    print("MOVA Video Generation")
    print("=" * 50)
    print(f"Prompt: {args.prompt}")
    print(f"Output: {args.output}")
    print(f"Resolution: {args.width}x{args.height}")
    print(f"Frames: {args.num_frames} @ {args.fps}fps")
    if args.ref_path:
        print(f"Reference: {args.ref_path}")
    print("=" * 50)
    print("\nStarting generation...\n")
    
    # Run inference
    subprocess.run(cmd, check=True)
    
    print("\n" + "=" * 50)
    print(f"✓ Video generated successfully: {args.output}")
    print("=" * 50)

if __name__ == '__main__':
    main()
PYTHON_EOF

    chmod +x "${MOVA_DIR}/generate_video.py"
    
    printf "✓ Launch scripts created:\n"
    printf "  - ${MOVA_DIR}/launch_mova.sh\n"
    printf "  - ${MOVA_DIR}/generate_video.py\n"
}

function provisioning_print_end() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#     ✓ MOVA Installation Complete!          #\n"
    printf "#                                            #\n"
    printf "##############################################\n\n"
    
    printf "📁 Installation paths:\n"
    printf "  MOVA code: ${MOVA_DIR}\n"
    printf "  Models: ${WORKSPACE}/models/\n\n"
    
    printf "🚀 Quick start:\n"
    printf "  cd ${MOVA_DIR}\n"
    printf "  ./generate_video.py --prompt 'A beautiful sunset over the ocean with waves' --output sunset.mp4\n\n"
    
    printf "📖 Full usage:\n"
    printf "  ./generate_video.py --help\n\n"
    
    printf "💡 Manual command:\n"
    printf "  export CP_SIZE=2\n"
    printf "  export CKPT_PATH=${WORKSPACE}/models/MOVA-720p/\n"
    printf "  torchrun --nproc_per_node=\$CP_SIZE scripts/inference_single.py \\\\\n"
    printf "    --ckpt_path \$CKPT_PATH --cp_size \$CP_SIZE \\\\\n"
    printf "    --height 720 --width 1280 \\\\\n"
    printf "    --prompt 'Your description' \\\\\n"
    printf "    --output_path output.mp4\n\n"
    
    printf "⚠️  Requirements:\n"
    printf "  - GPU: 2x GPUs with 24GB+ VRAM recommended\n"
    printf "  - Disk: ~60GB for models\n"
    printf "  - Python: 3.10+\n\n"
}

# Запуск установки
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
else
    echo "Provisioning disabled by /.noprovisioning file"
fi
