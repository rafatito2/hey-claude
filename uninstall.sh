#!/bin/zsh
# Desinstala Claude Voice: cierra la app, quita el arranque automático y borra la app compilada.
# Conserva tu configuración e historial en ~/claude-voice (bórralos a mano si quieres).
LABEL="com.heyclaude.voice"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

pkill -x ClaudeVoice >/dev/null 2>&1 || true
launchctl unload "$AGENT" >/dev/null 2>&1 || true
rm -f "$AGENT"
rm -rf "$HOME/claude-voice/ClaudeVoice.app"
echo "Claude Voice desinstalada. Tu configuración sigue en ~/claude-voice (contexto.md, historial, recordatorios)."
echo "Los permisos de micrófono y voz se pueden quitar en Ajustes del Sistema → Privacidad y seguridad."
