#!/bin/bash
# Calendarios de Apple (app Calendario) para Hey Claude. Fechas: YYYY-MM-DD o "YYYY-MM-DD HH:MM".
# Uso:
#   calendario.sh calendarios
#   calendario.sh listar DESDE HASTA [calendario]          -> uid | calendario | inicio | fin | título   (una línea por evento)
#   calendario.sh duplicados DESDE HASTA [calendario]      -> grupos con mismo título+inicio+fin en el mismo calendario; los uid a borrar (se conserva uno)
#   calendario.sh borrar UID [UID...]                      -> borra esos eventos (una serie repetitiva se borra entera)
#   calendario.sh crear "título" "INICIO" "FIN" [calendario]
#   calendario.sh borrar-calendario "nombre"              -> quita un calendario entero (p. ej. una suscripción/feed que sobra)
set -euo pipefail
cmd="${1:-}"; shift || true

osa() { /usr/bin/osascript "$@"; }

# Fecha AppleScript desde texto (día a 1 antes de cambiar el mes para no desbordar)
DATEFN='
on toDate(s)
  set d to current date
  set day of d to 1
  set year of d to (text 1 thru 4 of s) as integer
  set month of d to (text 6 thru 7 of s) as integer
  set day of d to (text 9 thru 10 of s) as integer
  if (length of s) > 10 then
    set time of d to ((text 12 thru 13 of s) as integer) * 3600 + ((text 15 thru 16 of s) as integer) * 60
  else
    set time of d to 0
  end if
  return d
end toDate
on pad(n)
  if n < 10 then return "0" & n
  return "" & n
end pad
on fmt(d)
  return (year of d as text) & "-" & pad(month of d as integer) & "-" & pad(day of d) & " " & pad(hours of d) & ":" & pad(minutes of d)
end fmt
'

case "$cmd" in
  calendarios)
    osa -e 'tell application "Calendar" to get name of every calendar' | tr ',' '\n' | sed 's/^ *//'
    ;;
  listar)
    from="${1:?falta DESDE}"; to="${2:?falta HASTA}"; cal="${3:-}"
    osa -e "$DATEFN" -e "
      set d1 to toDate(\"$from\")
      set d2 to toDate(\"$to\")
      set out to {}
      tell application \"Calendar\"
        if \"$cal\" is \"\" then
          set cals to every calendar
        else
          set cals to {calendar \"$cal\"}
        end if
        repeat with c in cals
          set cname to name of c
          set evs to (every event of c whose start date ≥ d1 and start date < d2)
          repeat with e in evs
            set end of out to (uid of e) & tab & cname & tab & my fmt(start date of e) & tab & my fmt(end date of e) & tab & (summary of e)
          end repeat
        end repeat
      end tell
      set AppleScript's text item delimiters to linefeed
      return out as text
    " | sort -t $'\t' -k3,3
    ;;
  duplicados)
    from="${1:?falta DESDE}"; to="${2:?falta HASTA}"; cal="${3:-}"
    "$0" listar "$from" "$to" "$cal" | python3 -c '
import sys
groups = {}
for line in sys.stdin:
    p = line.rstrip("\n").split("\t")
    if len(p) < 5: continue
    key = (p[1], p[2], p[3], p[4].strip().lower())
    groups.setdefault(key, []).append(p[0])
dups = {k: v for k, v in groups.items() if len(v) > 1}
# Mismo evento en calendarios distintos (p. ej. una suscripción que repite el calendario principal)
cross = {}
for (calname, start, end, title), uids in groups.items():
    cross.setdefault((start, end, title), []).append((calname, uids[0]))
cross = {k: v for k, v in cross.items() if len(v) > 1}
if not dups and not cross:
    print("Sin duplicados."); sys.exit(0)
if dups:
    total = sum(len(v) - 1 for v in dups.values())
    print(f"{len(dups)} grupos repetidos dentro del mismo calendario, {total} eventos sobrantes (se conserva uno por grupo):")
    for (calname, start, end, title), uids in sorted(dups.items(), key=lambda x: x[0][1]):
        print(f"- {title} | {calname} | {start} -> {end} | {len(uids)} copias | borrar: {' '.join(uids[1:])}")
    print("UIDS_A_BORRAR: " + " ".join(u for v in dups.values() for u in v[1:]))
if cross:
    print(f"{len(cross)} eventos que están en más de un calendario (decidir cuál conservar; si uno es una suscripción, conviene borrar-calendario):")
    bycal = {}
    for (start, end, title), pairs in sorted(cross.items()):
        print(f"- {title} | {start} -> {end} | " + " ; ".join(f"{c}: {u}" for c, u in pairs))
        for c, u in pairs: bycal.setdefault(c, []).append(u)
    for c, us in bycal.items():
        print(f"UIDS_EN_{c.replace(' ', '_')}: " + " ".join(us))
'
    ;;
  borrar)
    [ $# -gt 0 ] || { echo "faltan UID"; exit 1; }
    n=0
    for uid in "$@"; do
      r=$(osa -e "
        tell application \"Calendar\"
          set done to false
          repeat with c in every calendar
            try
              set e to (first event of c whose uid is \"$uid\")
              delete e
              set done to true
              exit repeat
            end try
          end repeat
          return done
        end tell
      ")
      if [ "$r" = "true" ]; then n=$((n+1)); else echo "no encontrado: $uid"; fi
    done
    echo "Borrados: $n"
    ;;
  crear)
    title="${1:?falta título}"; from="${2:?falta INICIO}"; to="${3:?falta FIN}"; cal="${4:-}"
    osa -e "$DATEFN" -e "
      set d1 to toDate(\"$from\")
      set d2 to toDate(\"$to\")
      tell application \"Calendar\"
        if \"$cal\" is \"\" then
          set c to first calendar whose writable is true
        else
          set c to calendar \"$cal\"
        end if
        set e to make new event at end of events of c with properties {summary:\"$title\", start date:d1, end date:d2}
        return \"Creado en \" & (name of c) & \": \" & (uid of e)
      end tell
    "
    ;;
  borrar-calendario)
    name="${1:?falta el nombre del calendario}"
    osa -e "
      tell application \"Calendar\"
        set n to count of (every event of calendar \"$name\")
        delete calendar \"$name\"
        return \"Calendario borrado: $name (\" & n & \" eventos)\"
      end tell
    "
    ;;
  *)
    sed -n '2,10p' "$0"; exit 1
    ;;
esac
