#!/bin/bash
# Notificaciones y mensajes para Hey Claude.
#   mensajes.sh notificaciones            -> lo que hay ahora en el Centro de notificaciones (por Accesibilidad)
#   mensajes.sh mensajes [N] [contacto]   -> últimos N mensajes de Mensajes/iMessage (por defecto 5), opcionalmente de un contacto.
#                                            Lee ~/Library/Messages/chat.db: requiere Acceso total al disco para Claude Voice.
#   mensajes.sh whatsapp [N] [contacto]   -> últimos N mensajes de WhatsApp (por defecto 6), opcionalmente de un contacto o grupo.
#                                            Lee la base local de la app de WhatsApp (ChatStorage.sqlite), al instante.
#   mensajes.sh whatsapp noleidos         -> chats con mensajes sin leer y cuántos.
# Nota: los AppleScript van en funciones porque el bash 3.2 de macOS no soporta bien un heredoc dentro de $( ).
cmd="${1:-}"; shift || true

# Traduce los errores de Accesibilidad a un marcador que la app entiende
reporta() {
  local out="$1"
  case "$out" in
    *"assistive access"*|*"acceso asistido"*) echo "SIN_ACCESIBILIDAD: el proceso que ejecuta esto no está en Privacidad → Accesibilidad" ;;
    *"execution error"*|*"Can’t get"*|*"Can't get"*) echo "No encontré lo que buscaba en la app (¿está abierta y a la vista la ventana?). Detalle: ${out:0:160}" ;;
    *) echo "$out" ;;
  esac
}

nc_read() {
  /usr/bin/osascript 2>&1 <<'OSA'
-- Cada notificación es: group 1 of UI element N of scroll area 1 of group 1 of window "Notification Center",
-- con static texts: app o título, subtítulo (opcional) y cuerpo.
tell application "System Events"
  if not (exists process "NotificationCenter") then return "Sin notificaciones."
  tell process "NotificationCenter"
    set out to {}
    repeat with w in windows
      try
        repeat with el in (every UI element of scroll area 1 of group 1 of w)
          try
            set texts to value of every static text of group 1 of el
            set AppleScript's text item delimiters to " · "
            set t to texts as text
            set AppleScript's text item delimiters to ""
            if t is not "" then set end of out to t
          end try
        end repeat
      end try
    end repeat
    set AppleScript's text item delimiters to linefeed
    if (count of out) = 0 then return "Sin notificaciones a la vista."
    return out as text
  end tell
end tell
OSA
}

case "$cmd" in
  notificaciones)
    reporta "$(nc_read)"
    ;;
  whatsapp)
    n="${1:-6}"; who="${2:-}"
    python3 - "$n" "$who" <<'PY'
import sqlite3, sys, os, datetime, glob
arg = sys.argv[1]; who = sys.argv[2].lower()
db = os.path.expanduser("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
if not os.path.exists(db):
    print("No encuentro la base de WhatsApp: ¿está instalada la app de WhatsApp para Mac?"); sys.exit(2)
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.execute("select 1 from ZWAMESSAGE limit 1")
except Exception:
    try: con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
    except Exception as e: print("No puedo leer la base de WhatsApp:", e); sys.exit(2)
def when(ts):
    return datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=ts or 0)
if arg == "noleidos":
    rows = con.execute("select coalesce(ZPARTNERNAME, ZCONTACTJID), ZUNREADCOUNT, ZLASTMESSAGEDATE from ZWACHATSESSION where ZUNREADCOUNT > 0 and ZHIDDEN = 0 order by ZLASTMESSAGEDATE desc limit 15").fetchall()
    if not rows: print("Sin mensajes sin leer."); sys.exit(0)
    total = sum(r[1] for r in rows)
    print(f"{total} sin leer en {len(rows)} chats:")
    for name, cnt, ts in rows: print(f"- {name}: {cnt} ({when(ts):%d/%m %H:%M})")
    sys.exit(0)
n = int(arg)
rows = con.execute("""
    select m.ZMESSAGEDATE, m.ZISFROMME, coalesce(s.ZPARTNERNAME, s.ZCONTACTJID), m.ZTEXT, gm.ZCONTACTNAME, s.ZSESSIONTYPE, s.Z_PK
    from ZWAMESSAGE m
    join ZWACHATSESSION s on s.Z_PK = m.ZCHATSESSION
    left join ZWAGROUPMEMBER gm on gm.Z_PK = m.ZGROUPMEMBER
    where m.ZTEXT is not null and m.ZTEXT != '' and s.ZHIDDEN = 0
    order by m.ZMESSAGEDATE desc limit 600""").fetchall()
out = []
seen_chats = set()
for ts, from_me, chat, text, member, stype, chat_id in rows:
    if who and who not in (chat or "").lower() and who not in (member or "").lower(): continue
    # Sin contacto: el último mensaje de cada chat (más útil que N mensajes seguidos del mismo grupo)
    if not who:
        if chat_id in seen_chats: continue
        seen_chats.add(chat_id)
    sender = "yo" if from_me else (f"{chat} ({member})" if member and stype == 1 else chat)
    target = chat if from_me else "yo"
    out.append(f"{when(ts):%Y-%m-%d %H:%M} | {sender} -> {target} | {text.replace(chr(10), ' ')[:300]}")
    if len(out) >= n: break
print("\n".join(out) if out else "No hay mensajes" + (f" de {sys.argv[2]}" if who else "") + " en WhatsApp.")
PY
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
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
