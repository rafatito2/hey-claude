#!/bin/bash
# Notificaciones y mensajes para Hey Claude.
#   mensajes.sh notificaciones            -> lo que hay ahora en el Centro de notificaciones (por Accesibilidad)
#   mensajes.sh mensajes [N] [contacto]   -> últimos N mensajes de Mensajes/iMessage (por defecto 5), opcionalmente de un contacto.
#                                            Lee ~/Library/Messages/chat.db: requiere Acceso total al disco para Claude Voice.
cmd="${1:-}"; shift || true
case "$cmd" in
  notificaciones)
    /usr/bin/osascript <<'OSA'
tell application "System Events"
  if not (exists process "NotificationCenter") then return "Sin notificaciones."
  tell process "NotificationCenter"
    set out to {}
    repeat with w in windows
      try
        repeat with el in (every UI element of w)
          try
            set d to description of el
            if d is not "" and d is not missing value then set end of out to d
          end try
        end repeat
      end try
    end repeat
    if (count of out) = 0 then
      try
        set out to value of every static text of every group of every scroll area of every group of every window
      end try
    end if
    set AppleScript's text item delimiters to linefeed
    if (count of out) = 0 then return "Sin notificaciones a la vista."
    return out as text
  end tell
end tell
OSA
    ;;
  mensajes)
    n="${1:-5}"; who="${2:-}"
    python3 - "$n" "$who" <<'PY'
import sqlite3, sys, os, datetime
n = int(sys.argv[1]); who = sys.argv[2].lower()
db = os.path.expanduser("~/Library/Messages/chat.db")
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute("""
        select m.date, m.is_from_me, coalesce(h.id,''), m.text, m.attributedBody, coalesce(c.display_name,'')
        from message m
        left join handle h on h.ROWID = m.handle_id
        left join chat_message_join cmj on cmj.message_id = m.ROWID
        left join chat c on c.ROWID = cmj.chat_id
        order by m.date desc limit 400""").fetchall()
except Exception as e:
    print("No puedo leer los mensajes: Claude Voice necesita Acceso total al disco (Ajustes del Sistema → Privacidad y seguridad). Detalle:", e); sys.exit(2)
def body(text, blob):
    # Los mensajes nuevos guardan el texto en attributedBody (typedstream): el texto sigue a "NSString" y "+" con su largo
    if text: return text
    if not blob: return ""
    i = blob.find(b"NSString")
    if i < 0: return ""
    j = blob.find(b"+", i)
    if j < 0: return ""
    k = j + 1
    ln = blob[k]
    if ln == 0x81: ln = int.from_bytes(blob[k+1:k+3], "little"); k += 3
    else: k += 1
    try: return blob[k:k+ln].decode("utf-8", "ignore")
    except Exception: return ""
out = []
for date, from_me, handle, text, blob, chat in rows:
    t = body(text, blob).strip()
    if not t: continue
    name = chat or handle
    if who and who not in name.lower() and who not in handle.lower(): continue
    ts = datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=date / 1e9 if date > 1e12 else date)
    out.append(f"{ts:%Y-%m-%d %H:%M} | {'yo' if from_me else name} -> {name if from_me else 'yo'} | {t[:300]}")
    if len(out) >= n: break
print("\n".join(out) if out else "No hay mensajes" + (f" de {sys.argv[2]}" if who else "") + ".")
PY
    ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
