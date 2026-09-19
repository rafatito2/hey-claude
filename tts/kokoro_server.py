#!/usr/bin/env python3
"""Servidor local de voz neuronal (Kokoro-82M) para Hey Claude.

Escucha solo en 127.0.0.1. Protocolo:
  GET  /health                     -> 200 "ok" cuando los modelos están cargados
  POST /tts  {"text","lang","voice","speed"} -> PCM float32 mono little-endian, cabecera X-Sample-Rate

Uso: kokoro_server.py [--port 8765] [--selftest]
"""
import argparse, json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

LANG_CODES = {"es": "e", "en": "a"}
DEFAULT_VOICE = {"es": "ef_dora", "en": "af_heart"}
SAMPLE_RATE = 24000

pipes = {}
lock = threading.Lock()


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def pipeline(lang):
    from kokoro import KPipeline
    code = LANG_CODES.get(lang, "e")
    with lock:
        if code not in pipes:
            t = time.time()
            pipes[code] = KPipeline(lang_code=code, repo_id="hexgrad/Kokoro-82M")
            log(f"modelo cargado para '{lang}' en {time.time() - t:.1f} s")
        return pipes[code]


def synth(text, lang="es", voice=None, speed=1.0):
    p = pipeline(lang)
    voice = voice or DEFAULT_VOICE.get(lang, "ef_dora")
    chunks = []
    for _, _, audio in p(text, voice=voice, speed=float(speed)):
        if audio is not None:
            a = audio.numpy() if hasattr(audio, "numpy") else np.asarray(audio)
            chunks.append(a.astype(np.float32))
    return np.concatenate(chunks) if chunks else np.zeros(0, np.float32)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # sin ruido en la consola
        pass

    def do_GET(self):
        if self.path == "/health":
            body = b"ok" if pipes else b"loading"
            self.send_response(200 if pipes else 503)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        if self.path != "/tts":
            self.send_response(404); self.end_headers(); return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = (req.get("text") or "").strip()
            if not text:
                self.send_response(400); self.end_headers(); return
            t = time.time()
            audio = synth(text, req.get("lang", "es"), req.get("voice"), req.get("speed", 1.0))
            data = audio.tobytes()
            log(f"{req.get('lang','es')} {len(text)} chars -> {len(audio)/SAMPLE_RATE:.1f} s de audio en {time.time()-t:.2f} s")
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:  # noqa: BLE001
            log(f"error: {e!r}")
            msg = repr(e).encode()
            self.send_response(500)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    try:
        import torch
        torch.set_num_threads(max(2, min(6, torch.get_num_threads())))
    except Exception:
        pass
    if args.selftest:
        for lang, text in (("es", "Hola, soy Claude. Así sueno con la voz neuronal."), ("en", "Hi, I'm Claude. This is my neural voice.")):
            t = time.time(); a = synth(text, lang)
            log(f"selftest {lang}: {len(a)/SAMPLE_RATE:.1f} s de audio en {time.time()-t:.2f} s")
        return
    # Precarga en segundo plano para que la primera frase no espere
    threading.Thread(target=lambda: (pipeline("es"), pipeline("en")), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"escuchando en 127.0.0.1:{args.port}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
