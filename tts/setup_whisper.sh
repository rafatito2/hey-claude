#!/bin/bash
# Instala whisper.cpp (Homebrew) y el modelo para el reconocimiento preciso local de Hey Claude.
# Uso: setup_whisper.sh [turbo|small]   (por defecto turbo; ambos se pueden tener)
set -euo pipefail
DIR="$HOME/claude-voice/whisper"; mkdir -p "$DIR"
command -v brew >/dev/null || { echo "Necesito Homebrew (https://brew.sh)"; exit 1; }
brew list --formula whisper-cpp >/dev/null 2>&1 || { echo "→ Instalando whisper.cpp"; brew install whisper-cpp; }
case "${1:-turbo}" in
  small) M="ggml-small-q5_1.bin" ;;
  *) M="ggml-large-v3-turbo-q5_0.bin" ;;
esac
if [ ! -f "$DIR/$M" ]; then
  echo "→ Descargando el modelo $M"
  curl -L --progress-bar -o "$DIR/$M.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$M" && mv "$DIR/$M.part" "$DIR/$M"
fi
echo "Listo: $DIR/$M. Activa 'Reconocimiento preciso con Whisper' en Ajustes de Claude Voice."
