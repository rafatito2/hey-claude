#!/bin/zsh
# Claude Voice - etapa 1
# Uso:  ask.sh "texto"        (o texto por stdin)
#       ask.sh --nueva        reinicia la conversación
# Variables: VOICE (default Paulina), SPEAK=0 para no hablar

DIR="$HOME/claude-voice"
SESSION_FILE="$DIR/.session"
LOG="$DIR/voice.log"
VOICE="${VOICE:-Paulina}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

cd "$DIR" || exit 1

if [[ "$1" == "--nueva" ]]; then
  rm -f "$SESSION_FILE"
  echo "Empezamos de cero."
  [[ "$SPEAK" != "0" ]] && say -v "$VOICE" "Empezamos de cero."
  exit 0
fi

if [[ -n "$1" ]]; then TEXT="$*"; else TEXT="$(cat)"; fi
TEXT="${TEXT## }"
if [[ -z "$TEXT" ]]; then
  echo "<<FIN>>"
  exit 0
fi

# Frases para terminar la conversación
if echo "$TEXT" | grep -qiE '^(listo|gracias|adi[oó]s|eso es todo|nada m[aá]s|ya|termina|terminar|hasta luego)\.?$'; then
  echo "<<FIN>>"
  [[ "$SPEAK" != "0" ]] && say -v "$VOICE" "Listo."
  exit 0
fi

# Frases de reinicio por voz
if echo "$TEXT" | grep -qiE '^(nueva conversaci[oó]n|empezar de nuevo|reinicia)'; then
  exec "$0" --nueva
fi

SYSTEM='Eres un asistente de voz en la Mac del usuario. Todo lo que recibes fue dictado por voz y tu respuesta será leída en voz alta.
Reglas:
- Responde en español, en 1 o 2 frases cortas, tono natural. Sin markdown, sin listas, sin código, sin URLs largas.
- Si te piden abrir una app usa: open -a "Nombre". Si te piden una página web usa: open -a "Google Chrome" "https://...".
- Si te piden hacer algo dentro de una página (buscar, leer, llenar), usa las herramientas de Chrome.
- Para acciones del sistema (volumen, música, etc.) usa osascript.
- Ejecuta la acción directamente y confirma en una frase corta. No pidas confirmación salvo que sea destructivo.
- Si el dictado tiene errores obvios, interpreta la intención más probable usando el contexto personal.
- Es una conversación continua: si necesitas aclarar algo, pregunta en una frase y el usuario te responderá por voz.'

if [[ -f "$DIR/contexto.md" ]]; then
  SYSTEM="$SYSTEM

Contexto personal del usuario. Tiene prioridad sobre cualquier interpretación literal: si el dictado se parece a una sigla o nombre de aquí, usa este significado y no adivines dominios:
$(cat "$DIR/contexto.md")"
fi

ALLOWED='Bash,Read,Glob,Grep,Write,Edit,WebSearch,WebFetch,mcp__claude-in-chrome__*'
DISALLOWED='Bash(rm:*),Bash(rm -rf:*),Bash(rmdir:*),Bash(srm:*),Bash(sudo:*),Bash(su:*),Bash(dd:*),Bash(mkfs:*),Bash(diskutil:*),Bash(shutdown:*),Bash(reboot:*),Bash(halt:*),Bash(launchctl:*),Bash(killall:*),Bash(pkill:*),Bash(kill:*),Bash(chmod:*),Bash(chown:*),Bash(defaults delete:*),Bash(git push:*),Bash(git reset:*),Bash(security:*)'

echo "[$(date '+%F %T')] > $TEXT" >> "$LOG"

if [[ -f "$SESSION_FILE" ]]; then
  SID="$(cat "$SESSION_FILE")"
  REPLY="$(claude -p "$TEXT" --resume "$SID" --chrome --allowedTools "$ALLOWED" --disallowedTools "$DISALLOWED" --append-system-prompt "$SYSTEM" 2>>"$LOG")"
  RC=$?
else
  SID="$(uuidgen | tr 'A-Z' 'a-z')"
  REPLY="$(claude -p "$TEXT" --session-id "$SID" --chrome --allowedTools "$ALLOWED" --disallowedTools "$DISALLOWED" --append-system-prompt "$SYSTEM" 2>>"$LOG")"
  RC=$?
  [[ $RC -eq 0 ]] && echo "$SID" > "$SESSION_FILE"
fi

if [[ $RC -ne 0 || -z "$REPLY" ]]; then
  # Si la sesión anterior se perdió, reinicia y reintenta una vez
  if [[ -f "$SESSION_FILE" ]]; then
    rm -f "$SESSION_FILE"
    exec "$0" "$TEXT"
  fi
  REPLY="Hubo un error, revisa el log."
fi

echo "[$(date '+%F %T')] < $REPLY" >> "$LOG"
echo "$REPLY"
[[ "$SPEAK" != "0" ]] && say -v "$VOICE" "$REPLY"
exit 0
