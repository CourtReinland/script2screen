#!/bin/bash
# Start Voicebox server for ScriptToScreen local voice generation
# Qwen TTS (voice cloning + speech synthesis) runs through this server

VOICEBOX_DIR="$HOME/voicebox"

if [ ! -d "$VOICEBOX_DIR" ]; then
    echo "Error: Voicebox not found at $VOICEBOX_DIR"
    echo "Install it with: git clone https://github.com/jamiepine/voicebox.git ~/voicebox"
    exit 1
fi

if [ ! -d "$VOICEBOX_DIR/backend/venv" ]; then
    echo "Error: Voicebox venv not found at $VOICEBOX_DIR/backend/venv"
    echo "Run the setup first (see README)."
    exit 1
fi

echo "=================================="
echo " Starting Voicebox Server"
echo "=================================="
echo ""
echo "API endpoint: http://127.0.0.1:17493"
echo "API docs:     http://127.0.0.1:17493/docs"
echo ""
echo "TTS Engines: Qwen3 (MLX), LuxTTS, Chatterbox"
echo ""
echo "Press Ctrl+C to stop"
echo "=================================="
echo ""

cd "$VOICEBOX_DIR"
source backend/venv/bin/activate
python -m uvicorn backend.main:app --port 17493
