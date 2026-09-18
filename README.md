# Hey Claude

Asistente de voz "hey claude" para macOS que conecta tu micrófono con [Claude Code](https://claude.com/claude-code). Dices **"hey claude"** y le pides cosas: abrir apps o páginas, leer y usar sitios en Chrome, revisar tu correo o calendario, poner recordatorios, crear documentos o simplemente preguntar. Responde con voz, en español o inglés, y muestra un widget flotante estilo Siri con lo que va haciendo.

Todo corre en tu Mac con **tu propia cuenta de Claude**. No hay servidores intermedios ni claves de terceros.

## Qué hace

- **Activación por voz** ("hey claude" u "oye claude"), por tecla (⌥⌘C), por clic en el widget o desde Siri con un Atajo.
- **Conversación continua**: tras cada respuesta sigue escuchando unos segundos; puedes interrumpirlo hablando encima, con el botón ■ del widget, o decir "para".
- **Respuesta en streaming**: empieza a leer la primera frase mientras genera el resto, resaltando la palabra que va diciendo.
- **Acciones en la Mac**: abre apps y páginas, ejecuta comandos de consulta (procesos, disco, batería…), crea y edita archivos, usa Chrome mediante la extensión *Claude in Chrome*, y Gmail/Google Calendar si los tienes conectados en Claude Code. Nunca borra archivos ni ejecuta comandos destructivos (lista de exclusión en el código).
- **Recordatorios y temporizadores** locales: "recuérdame en 20 minutos sacar la ropa", "pon un temporizador de 5 minutos", "remind me at 3 pm to call mom".
- **Memoria personal**: "recuerda que mi universidad es X" o datos que salgan en la conversación se guardan en `contexto.md` y se usan en cada orden.
- **Modelos por nivel**: preguntas simples con Haiku, lo demás con Sonnet, y el modelo grande solo si pides "piensa bien". Configurable en Ajustes.
- **Bilingüe**: entiende español e inglés con un solo reconocedor local de Apple, responde en el idioma de la orden y usa una voz distinta para cada idioma.
- **Cancelación de eco**: la voz de Claude sale por el mismo motor de audio que captura el micrófono, así no se oye a sí mismo; pausa lo que esté sonando (YouTube, Spotify) mientras conversas y lo reanuda al terminar.
- **Widget**: se encoge a un círculo en reposo, se puede arrastrar, tema claro u oscuro, orden escrita con ⌥⌘T para lugares con gente.

## Requisitos

- macOS 14 (Sonoma) o superior, Apple Silicon recomendado.
- Xcode o las Command Line Tools (`xcode-select --install`) para compilar.
- [Claude Code](https://claude.com/claude-code) instalado y con sesión iniciada (`claude`). Funciona con la suscripción Pro o Max; no requiere API key.
- Opcional: extensión [Claude in Chrome](https://claude.com/chrome) para navegar; voces "Mejorada" de Apple para mejor sonido.

## Instalación

Una sola línea (clona en `~/claude-voice` y ejecuta el instalador):

```bash
git clone https://github.com/rafatito2/hey-claude.git ~/claude-voice && ~/claude-voice/install.sh
```

O paso a paso:

```bash
git clone https://github.com/rafatito2/hey-claude.git ~/claude-voice
cd ~/claude-voice
./install.sh
```

El instalador comprueba los requisitos, compila la app, la registra para arrancar al iniciar sesión y la abre. La primera vez macOS pide permiso de **Micrófono** y **Reconocimiento de voz**: acéptalos.

Después:

1. Edita `~/claude-voice/contexto.md` con tus datos (universidad, sitios que usas, nombres). Claude lo lee en cada orden y lo va completando solo.
2. Descarga una voz mejorada: Ajustes del Sistema → Accesibilidad → Contenido hablado → Voz del sistema → Gestionar voces. Elígela en el ícono de la barra → Ajustes.
3. Para activarlo con Siri, crea un Atajo llamado "Claude" con una sola acción *Ejecutar script de shell*: `touch ~/claude-voice/.trigger`. Luego "Oye Siri, Claude".

## Uso

| Dices | Pasa |
|---|---|
| "hey claude, abre YouTube" | Abre Chrome en YouTube |
| "hey claude, revisa si tengo tareas en Canvas" | Navega, lee la página y te resume |
| "hey claude, qué app usa más procesador" | Consulta el sistema y responde |
| "recuérdame en 10 minutos tomar agua" | Recordatorio con voz y notificación |
| "recuerda que mi carrera es ingeniería" | Lo guarda en `contexto.md` |
| "nueva conversación" | Empieza de cero |
| "gracias, listo" | Cierra la conversación |

Menú de la barra: escuchar ahora, escribir una orden, nueva conversación, historial, contexto, vocabulario y Ajustes (voces, velocidad, espera tras responder, sonido, tema, modelos).

## Archivos

| Archivo | Para qué |
|---|---|
| `app/main.swift` | Toda la app (AppKit + Speech + AVFoundation) |
| `app/build.sh` | Compila `ClaudeVoice.app` |
| `contexto.md` | Tu memoria personal (no se sube al repo) |
| `vocabulario.txt` | Palabras que el reconocedor debe conocer |
| `modelos.txt` | Modelo por nivel de orden |
| `recordatorios.json`, `voice.log` | Recordatorios pendientes e historial (locales) |
| `ask.sh`, `make_shortcut.py` | Versión mínima por Atajo de Apple + dictado, sin app |

## Privacidad y seguridad

- El reconocimiento de voz es local (Apple, modo en el dispositivo). Solo el texto de tus órdenes viaja a Claude, con tu cuenta.
- La app ejecuta comandos en tu Mac en tu nombre. Tiene una lista de prohibidos (borrar, sudo, formatear, apagar, matar procesos, cambiar permisos, enviar correos) que puedes ampliar en `main.swift` (`disallowedTools`).
- Historial y contexto se guardan en texto plano en `~/claude-voice`. Están en `.gitignore`.
- Para ver trazas de todo lo que oye (solo para depurar): `defaults write com.heyclaude.voice debugTrace -bool true` y reinicia la app.

## Desinstalar

```bash
~/claude-voice/uninstall.sh
```

---

## English

Voice assistant for macOS built on Claude Code. Say "hey claude" and ask it to open apps or sites, browse in Chrome, check mail or calendar, set reminders, create files, or just answer questions. Streams the spoken reply with word highlighting, understands Spanish and English, cancels its own echo, and pauses your media while you talk. Requires macOS 14+, Xcode tools, and Claude Code signed in with your own subscription. Install with `./install.sh`; the UI and prompts are in Spanish but it replies in whichever language you speak.
