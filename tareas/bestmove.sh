#!/bin/bash
# Mejor jugada con Stockfish para una posición FEN.
# Uso:  ~/claude-voice/tareas/bestmove.sh "<FEN>" [milisegundos]
# Salida: la jugada en notación UCI (p. ej. e2e4) o "error: ..." si algo falla.
FEN="$1"; MS="${2:-1500}"
SF="$(command -v stockfish || echo /opt/homebrew/bin/stockfish)"
[ -x "$SF" ] || { echo "error: stockfish no está instalado (brew install stockfish)"; exit 1; }
[ -n "$FEN" ] || { echo "error: falta el FEN"; exit 1; }
OUT="$( { printf 'uci\nisready\nposition fen %s\ngo movetime %s\n' "$FEN" "$MS"; sleep "$(awk "BEGIN{print $MS/1000+0.5}")"; printf 'quit\n'; } | "$SF" 2>/dev/null )"
MOVE="$(printf '%s\n' "$OUT" | awk '/^bestmove/{print $2; exit}')"
[ -n "$MOVE" ] || { echo "error: sin respuesta de stockfish"; exit 1; }
echo "$MOVE"
