#!/bin/bash
# Start ComfyUI server for ScriptToScreen local generation
# Flux Kontext (images) and LTX Video (video) run through this server

COMFYUI_DIR="$HOME/ComfyUI"

if [ ! -d "$COMFYUI_DIR" ]; then
    echo "Error: ComfyUI not found at $COMFYUI_DIR"
    echo "Install it with: git clone https://github.com/comfyanonymous/ComfyUI.git ~/ComfyUI"
    exit 1
fi

if [ ! -d "$COMFYUI_DIR/venv" ]; then
    echo "Error: ComfyUI venv not found at $COMFYUI_DIR/venv"
    echo "Create it with:"
    echo "  cd ~/ComfyUI"
    echo "  python3 -m venv venv"
    echo "  source venv/bin/activate"
    echo "  pip install torch torchvision torchaudio"
    echo "  pip install -r requirements.txt"
    exit 1
fi

echo "=================================="
echo " Starting ComfyUI Server"
echo "=================================="
echo ""
echo "API endpoint: http://127.0.0.1:8188"
echo "Web UI:       http://127.0.0.1:8188"
echo ""
echo "Models loaded from: $COMFYUI_DIR/models/"
echo ""
echo "Press Ctrl+C to stop"
echo "=================================="
echo ""

cd "$COMFYUI_DIR"
source venv/bin/activate
python main.py --listen 127.0.0.1 --port 8188
