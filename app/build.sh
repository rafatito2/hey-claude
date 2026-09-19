#!/bin/zsh
# Compila Claude Voice en ~/claude-voice/ClaudeVoice.app
set -e
cd "$(dirname "$0")"
APP="$HOME/claude-voice/ClaudeVoice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -framework AppKit -framework Speech -framework AVFoundation -framework Carbon \
  -o "$APP/Contents/MacOS/ClaudeVoice" main.swift tasks.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Firma: con la identidad propia "Hey Claude Dev" si existe (app/make_identity.sh), así macOS conserva los permisos
# entre compilaciones; si no, firma ad hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Hey Claude Dev"' | head -1 | tr -d '"')"
SIGN="${IDENTITY:--}"
codesign --force -s "$SIGN" "$APP"
# Ayudante de calendario y recordatorios (EventKit) con su Info.plist embebido
TOOLS="$HOME/claude-voice/tareas"
mkdir -p "$TOOLS"
swiftc -O -swift-version 5 -framework EventKit -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker ../tareas/calendario-Info.plist \
  -o "$TOOLS/calendario" ../tareas/calendario.swift
codesign --force -s "$SIGN" "$TOOLS/calendario"
echo "Listo: $APP (firma: $SIGN)"
