#!/bin/zsh
# Instalador de Claude Voice: compila la app, la registra para arrancar al iniciar sesión y la abre.
# Uso:  ./install.sh
set -e

DIR="$HOME/claude-voice"
APP="$DIR/ClaudeVoice.app"
LABEL="com.heyclaude.voice"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

say_step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }
fail() { printf "\n\033[31mError:\033[0m %s\n" "$1"; exit 1; }

say_step "Comprobando requisitos"
[[ "$(uname)" == "Darwin" ]] || fail "Claude Voice solo funciona en macOS."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MAJOR" -ge 14 ]] || fail "Necesita macOS 14 (Sonoma) o superior. Tienes $(sw_vers -productVersion)."
xcode-select -p >/dev/null 2>&1 || fail "Faltan las herramientas de Xcode. Ejecuta:  xcode-select --install  y vuelve a correr este script."
command -v swiftc >/dev/null 2>&1 || fail "No encuentro swiftc. Instala Xcode o las Command Line Tools."
if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  fail "No encuentro Claude Code. Instálalo desde https://claude.com/claude-code y luego ejecuta:  claude  para iniciar sesión."
fi
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
if ! "$CLAUDE_BIN" auth status 2>/dev/null | grep -q '"loggedIn": true'; then
  fail "Claude Code no tiene sesión iniciada. Ejecuta:  claude  e inicia sesión con tu cuenta, luego vuelve a correr este script."
fi
echo "macOS $(sw_vers -productVersion), Swift $(swiftc --version 2>/dev/null | head -1 | sed 's/.*version //;s/ .*//'), Claude Code $($CLAUDE_BIN --version 2>/dev/null | head -1)"

# El proyecto debe vivir en ~/claude-voice (la app guarda ahí su configuración)
SRC="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SRC" != "$DIR" ]]; then
  say_step "Copiando el proyecto a $DIR"
  mkdir -p "$DIR"
  rsync -a --exclude .git --exclude ClaudeVoice.app "$SRC/" "$DIR/"
fi
cd "$DIR"

say_step "Preparando configuración"
[[ -f contexto.md ]] || cp contexto.example.md contexto.md
[[ -f vocabulario.txt ]] || cp vocabulario.example.txt vocabulario.txt
[[ -f modelos.txt ]] || cat > modelos.txt <<'EOF'
# Qué modelo usa Claude Voice según la orden. Alias válidos: haiku, sonnet, opus, default
simple=haiku
normal=sonnet
profundo=default
EOF
chmod +x ask.sh app/build.sh tareas/bestmove.sh

say_step "Compilando la app"
./app/build.sh

say_step "Registrando arranque al iniciar sesión"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl unload "$AGENT" >/dev/null 2>&1 || true
launchctl load "$AGENT"

say_step "Abriendo Claude Voice"
pkill -x ClaudeVoice >/dev/null 2>&1 || true
sleep 1
open "$APP"

cat <<'EOF'

Listo. La primera vez macOS te pedirá dos permisos: Micrófono y Reconocimiento de voz. Acéptalos.
Luego di "hey claude" seguido de tu orden, o presiona ⌥⌘C.

Recomendado:
  - Descarga una voz "Mejorada": Ajustes del Sistema → Accesibilidad → Contenido hablado → Voz del sistema → Gestionar voces.
  - Edita ~/claude-voice/contexto.md con tus datos (universidad, sitios que usas, etc.).
  - Instala la extensión "Claude in Chrome" si quieres que navegue por ti.

Para desinstalar:  ./uninstall.sh
EOF
