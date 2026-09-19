#!/bin/bash
# Instala la voz neuronal local (Kokoro-82M, Apache 2.0) en ~/claude-voice/tts.
# Todo queda en tu Mac: el modelo se descarga una vez de huggingface.co/hexgrad/Kokoro-82M (~330 MB).
set -euo pipefail
DIR="$HOME/claude-voice/tts"
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR"
if ! command -v uv >/dev/null; then
  command -v brew >/dev/null || { echo "Necesito Homebrew (https://brew.sh) para instalar uv"; exit 1; }
  brew install uv
fi
echo "→ Entorno de Python 3.12 en $DIR/venv"
uv venv --python 3.12 --quiet "$DIR/venv"
echo "→ Instalando kokoro (trae PyTorch, unos minutos)"
uv pip install --python "$DIR/venv/bin/python" --quiet "kokoro>=0.9.4" "soundfile" "numpy"
# Modelo de spaCy para el inglés (si no está, kokoro intenta instalarlo solo y falla fuera del venv)
uv pip install --python "$DIR/venv/bin/python" --quiet "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
cp "$SRC/kokoro_server.py" "$DIR/kokoro_server.py"
echo "→ Descargando el modelo y probando las dos voces"
"$DIR/venv/bin/python" "$DIR/kokoro_server.py" --selftest
echo "Listo. Activa 'Voz neuronal (Kokoro)' en Ajustes de Claude Voice."
