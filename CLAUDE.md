# Hey Claude — guía del proyecto

Asistente de voz "hey claude" para macOS construido sobre Claude Code. Este archivo explica cómo está hecho, cómo se trabaja en él y qué decisiones no son obvias, para que cualquier sesión (humana o de Claude Code) pueda retomarlo sin contexto previo.

## Qué es y dónde vive cada cosa

| Ruta | Qué es |
|---|---|
| `~/Developer/Projects/hey-claude` (este repo) | Código fuente. Público en https://github.com/rafatito2/hey-claude |
| `~/claude-voice/` | Carpeta de **datos** de la app en cada Mac. No se versiona. Contiene `ClaudeVoice.app` (compilada), `contexto.md` (memoria personal), `vocabulario.txt`, `correcciones.txt` (dictado → corrección, se aplica a la orden antes de enviarla), `modelos.txt`, `voice.log` (historial), `app.log` (eventos), `recordatorios.json`, `rutinas.json` (órdenes programadas), `uso.json` (tokens y costo por día, modelo y tipo), `.session` / `.session_time`, `tareas/` (script de ajedrez, `historial.txt` con las tareas terminadas y archivos de trabajo de tareas) y copias de `ask.sh` / `make_shortcut.py`. |
| `app/main.swift` | Toda la app menos las tareas: audio, reconocimiento, voz, widget, ajustes, historial, controlador. ~3,000 líneas, un solo archivo a propósito (compila con `swiftc` sin Xcode project). |
| `app/tasks.swift` | Tareas largas en segundo plano y panel de tareas. |
| `app/build.sh` | Compila ambos archivos en `~/claude-voice/ClaudeVoice.app` con firma ad hoc. |
| `app/Info.plist` | Bundle `com.heyclaude.voice`, permisos de micrófono/voz, `LSUIElement` (sin Dock). |
| `app/Assets/` | Ícono (`make_icon.swift` lo genera; `AppIcon.icns`, `logo-*.png`). |
| `install.sh` / `uninstall.sh` | Instalador para usuarios: comprueba requisitos, copia los archivos de ejecución a `~/claude-voice`, compila, registra el LaunchAgent `com.heyclaude.voice` y abre la app. |
| `ask.sh`, `make_shortcut.py` | Versión mínima por Atajo de Apple (dictado → Claude → voz). Sigue sirviendo para disparar la app desde Siri (`touch ~/claude-voice/.trigger`). |
| `tts/kokoro_server.py`, `tts/setup_kokoro.sh` | Voz neuronal local opcional (Kokoro-82M). El instalador crea `~/claude-voice/tts/venv` (Python 3.12 con uv, PyTorch, kokoro, modelo de spaCy) y copia el servidor; la app lo arranca y apaga sola (`NeuralVoice`). Log en `~/claude-voice/tts/tts.log`. |
| `tareas/bestmove.sh` | Devuelve la mejor jugada de Stockfish para un FEN. Las tareas de ajedrez lo llaman en vez de hablar con Stockfish directamente. |

## Ciclo de trabajo

```bash
./app/build.sh                                   # compila (avisos de Sendable son normales)
pkill -x ClaudeVoice; open ~/claude-voice/ClaudeVoice.app   # relanzar (tarda ~25 s en estar listo por la cancelación de eco)
tail -f ~/claude-voice/app.log                   # eventos; con debugTrace también "oí[es]: ..." (todo lo que transcribe)
tail -f ~/claude-voice/voice.log                 # órdenes, respuestas, hitos de tareas, sesiones
defaults write com.heyclaude.voice debugTrace -bool true   # trazas detalladas (reiniciar la app)
```

Ganchos de prueba por archivo (solo con `debugTrace` activo), en `~/claude-voice/`:

- `.trigger` → equivale a ⌥⌘C (escuchar sin palabra de activación). También lo usa Siri.
- `.type` con texto → orden escrita (respuesta en pantalla, sin voz). Sirve para probar todo el flujo sin micrófono: `echo "qué hora es" > ~/claude-voice/.type`.
- `.say` con líneas de texto → la app las lee frase por frase como si fueran una respuesta (prueba de voz, resaltado y fin de habla).

Una prueba de tarea larga: `echo "en segundo plano, crea en el escritorio prueba.txt con dos refranes" > .type`, esperar el plan (~5 s), `echo "sí" > .type`.

La cancelación de eco elimina del micrófono el audio que sale por las bocinas, así que **`say` no sirve para simular al usuario** mientras la app corre; usa los ganchos.

Commits: mensaje en español, sin líneas de atribución de Claude (regla global del usuario), autor `rafatito2` con el correo noreply de GitHub.

## Arquitectura (main.swift)

- **Listener**: `AVAudioEngine` con voice processing (cancelación de eco) siempre instalado; toma el canal 0 de la entrada (VP entrega 9 canales), lo convierte a mono 16 kHz y alimenta un `SFSpeechRecognizer` `es-US` local (el único español con modo local en la Mac del autor; entiende también inglés razonablemente). `isVoiceProcessingBypassed` está en `true` salvo mientras Claude habla, porque VP resta sensibilidad al micrófono. Reinicios del reconocedor con freno de 1.5 s si falla al instante. Se recupera solo ante `.AVAudioEngineConfigurationChange` (AirPods, etc.).
- **Speaker**: `AVSpeechSynthesizer.write` → buffers → `AVAudioPlayerNode` en el mismo motor (así la cancelación de eco conoce la voz de Claude). Con la voz neuronal activa (`neuralVoice`), `writeNeural` pide a `NeuralVoice` (POST 127.0.0.1:8765/tts, PCM float32 24 kHz) el audio de la frase entera y lo programa en el mismo nodo; la frase siguiente se genera mientras suena la actual (~1.2 s por frase de 6 s en un M1 Max, sin huecos). Tres fallos seguidos → voz de Apple hasta reiniciar. Cada frase es un `Utt` con su propio cronómetro; el fin se detecta por buffer vacío, delegado, inactividad de 0.7 s o 3 s sin audio. Resaltado de palabras proporcional al tiempo. Voz por idioma de cada frase (`NLLanguageRecognizer`).
- **Overlay**: `NSPanel` flotante no activable; en reposo se contrae a un círculo arrastrable; máscara redondeada sobre `NSVisualEffectView` (el `cornerRadius` de la capa no basta). Botones ■ (interrumpir), ✕ (cerrar conversación) y 🔊 (silenciar la voz: `mutedVoice` en UserDefaults; `silent` = orden escrita **o** silenciado, así el texto sigue en pantalla y la promoción a segundo plano solo se salta para las escritas). Doble Esc (menos de 0.8 s) equivale a ■: es un hotkey de Carbon que solo se registra mientras el estado no es `idle` (se activa en el `didSet` de `state`), para no robarle la tecla a otras apps en reposo; se exige doble porque un Esc suelto suele ir dirigido a otra app.
- **PersistentClaude**: un proceso `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --chrome ...` vivo que recibe órdenes por stdin. `send()` inicia un turno; `steer()` inyecta un mensaje **a mitad de turno** (Claude lo atiende en la siguiente pausa entre herramientas; probado). `interruptTurn()` manda `{"type":"control_request","request":{"subtype":"interrupt"}}`: Claude Code cierra el turno con un `result` de error en ~30 ms y el proceso sigue vivo (probado); mientras llega ese `result` se ignora todo y una orden nueva espera en `pendingSend`. Si no responde en 4 s se apaga como antes. `cancel()` sigue matando el proceso y se usa solo para tareas. Reinicia solo si cambia el modelo o el esfuerzo; un cambio en `contexto.md` viaja dentro de la siguiente orden. `--effort low` + `MAX_THINKING_TOKENS=1024` para tareas "rápidas".
- **Controller**: máquina de estados `idle / listening / thinking / speaking`. Activación por `wakeRegex` ("hey|oye|hola" + "claude|cloud|clau|icloud…") o `bareWakeRegex` (el nombre solo al inicio de un segmento). Acumula segmentos del reconocedor (que reinicia el texto tras pausas) sin repetir palabras de borde, descarta el eco de la última frase de Claude, y detecta el fin de la orden tras 1.9 s de silencio. Un segmento nuevo se detecta porque el texto se encoge **o porque ya no empieza con la misma palabra** (con "Hey Claude" + pausa + orden, el texto nuevo no es más corto y antes se perdía la orden entera). Red de seguridad: si tras 4 s escuchando se oyeron dos o más palabras y ninguna se aceptó como orden, se toman tal cual. Antes de enviar se aplican las `correcciones.txt`. Rutas locales sin modelo: hora, fecha, batería, recordatorios/temporizadores, memoria ("recuerda que…"), dictado en la app activa (⌘V por CGEvent, requiere Accesibilidad), captura de pantalla (requiere Grabación de pantalla), portapapeles y selección, control del Mac (`macControl`: brillo por key codes 144/145, volumen y silencio por `set volume`, bloqueo ⌃⌘Q, dormir, cerrar apps por `NSRunningApplication`, música en Music/Spotify, `blueutil` para Bluetooth, `shortcuts run` para no molestar), historial (`searchHistory` sobre voice.log con "hoy/ayer/la semana pasada") y rutinas (`Routines.parse`).
- **Ojos**: `eyesRegex` ("¿qué es esto?") captura solo la ventana activa (`frontWindowID` por `CGWindowListCopyWindowInfo` + `screencapture -l`); `regionRegex` ("esta zona") usa `screencapture -i` para que el usuario marque; `screenRegex` sigue capturando la pantalla entera. Ojo: la firma ad hoc cambia con cada compilación y macOS puede olvidar el permiso de Grabación de pantalla; el log anota "(sin permiso de Grabación de pantalla)" cuando pasa.
- **Rutinas** (`Routines`, `rutinas.json`): hora, minuto y días; se disparan en una ventana de 15 min cuando el asistente está en reposo y sin tareas, una vez al día, por `fireRoutine` que entra en `commit` como si fuera voz. **Memoria** (`MemoryFile`): las líneas nuevas de `contexto.md` llevan la fecha entre paréntesis al final para poder resumir la semana (`weeklyMemorySummaryIfDue`, una vez cada 7 días en reposo entre 9 y 21 h); las antiguas sin fecha se respetan.
- **Widget con estados**: `LogoView.taskProgress/taskBusy/attention` dibujan el anillo (progreso, giro o azul latiendo) y `updateWidgetTaskState` los alimenta desde `tasks.onChange`; la miniatura de Chrome del panel se captura cada 3 s con `CGWindowListCreateImage` solo si hay tarea, panel visible y permiso de pantalla.
- **Auriculares**: `Listener.currentOutput()` consulta CoreAudio (transporte Bluetooth, USB con nombre de auriculares o fuente 'hdpn' de la salida integrada); con auriculares `setEchoActive` no activa la cancelación de eco y `checkLoudInterrupt` usa umbral y tiempo menores.
- **Uso**: `UsageStore` acumula por día y modelo lo que trae cada `result` de Claude Code. Ojo: en un proceso persistente `total_cost_usd` y `modelUsage` son **acumulados de la sesión** y `usage` es del turno (comprobado), así que `PersistentClaude.account` guarda lo último visto por modelo y suma solo la diferencia; se reinicia al arrancar el proceso. Ajustes está en `SettingsWindow` con `NSTabView` y rejillas `NSGridView` (etiquetas a la derecha, controles a la izquierda, centradas).
- **Permisos de herramientas**: lista blanca (`allowedTools`) de prefijos de Bash de consulta/apertura y escritura solo en Escritorio, Documentos y `contexto.md`, más Chrome, Gmail (sin enviar) y Calendar. Las tareas añaden `taskExtraTools` (python3, node, brew install, git, Stockfish, binarios de Homebrew, `~/claude-voice/tareas/**`). `disallowedTools` sigue bloqueando rm, sudo, kill, etc.

## Tareas largas (tasks.swift)

- Cada tarea terminada se anota en `~/claude-voice/tareas/historial.txt` (título → estado: resultado) y las últimas 5 viajan en la petición del plan, para que "vuelve a jugar contra Hikaru" tenga sentido en un proceso nuevo y para corregir nombres mal oídos.
- Se detectan por `longTaskRegex` ("en segundo plano", "juega", "gana", "investiga a fondo"…). Flujo: `planTask` pide solo el plan a un proceso propio (`ownSession: true`) → se lee el resumen y se espera confirmación; cualquier respuesta que no sea un "no" claro arranca la tarea, y si trae una indicación se le pasa → `startTask`.
- Protocolo de texto que el proceso debe seguir (en `taskPrompt`): `PLAN:` + pasos numerados, `PASO n:`, `HITO:`, `RESULTADO:`. `LongTask.ingest` lo parsea en streaming (separa marcadores pegados en una línea) y avanza los pasos también por parecido de texto. Si pasan 40 s sin hito, `TaskManager.tick` inyecta `ESTADO:` con `steer()`.
- Mientras una tarea corre, una orden que suene a instrucción sobre ella (`steerRegex` o palabras del título) se inyecta en su proceso; una tarea nueva solo con "en segundo plano" u "otra tarea". Una orden normal que pasa de 40 s se promueve a tarea (`promoteToBackground`) y la conversación sigue en un proceso nuevo.
- Anuncios por voz solo cuando el asistente está en reposo; se guarda únicamente el más reciente y se descarta si tiene más de 20 s. Notificaciones de macOS al terminar, fallar o agotar el tiempo (30 min por defecto, "tómate una hora" lo cambia; tope de 400 acciones).
- Al cerrar la app se apagan todos los procesos; al arrancar se eliminan huérfanos de instancias anteriores (`killOrphanClaudeProcesses`).

## Decisiones que costaron y no hay que deshacer

1. **Nunca matar un proceso de Claude para redirigirlo.** Las pestañas de Chrome pertenecen al proceso; un `--resume` en un proceso nuevo no las ve. Usar `steer()`.
2. **Dos reconocedores locales a la vez no funcionan** (el de español muere con error 1110 y la CPU sube al 170%). Bilingüe = un reconocedor `es-US` + detección de idioma por texto.
3. **No amplificar el micrófono por software**: distorsiona y produce palabras fantasma ("iCloud"). Subir el volumen de entrada del sistema sí ayuda.
4. **Alternar la cancelación de eco reiniciando el motor tarda 4 s**: por eso se deja instalada y se usa `isVoiceProcessingBypassed`.
5. **El sintetizador no avisa cuándo termina de generar** en esta Mac: por eso hay tres vías de fin de locución y un vigilante.
6. **Claude pega el texto de bloques consecutivos** ("...la partidaElijo la categoría..."): entre dos bloques de texto del mismo turno no hay salto de línea, así que `PersistentClaude` lo inserta; sin eso los HITO arrastran la narración siguiente.
7. **El reconocedor local reinicia el texto tras pausas y repite la última palabra**: de ahí `segmentPrefix`, `joinWithoutOverlap` y `stripReplyEcho`.
8. **Claude Code cuesta arrancar 2-4 s**: por eso el proceso persistente y el precalentamiento al abrir la app.

9. **Kokoro necesita el modelo de spaCy instalado a mano** (`en_core_web_sm`): si falta, misaki intenta instalarlo con `uv pip` fuera del venv y falla; el servidor corre con `VIRTUAL_ENV` apuntando al venv por lo mismo.
10. **Los avisos de `scheduleBuffer` llegan cuando el buffer termina**, no cuando empieza: con la voz neuronal (frase entera en un buffer) el resaltado arrancaba al final. Se programa una cabecera de 0.1 s con aviso y el resto detrás.
11. **`NSGridView.removeRow` no quita las vistas de la jerarquía**: al refrescar la tabla por modelo de Uso hay que hacer `removeFromSuperview` a cada celda antes, o los textos se apilan.

## Pendientes conocidos

- Whisper local como reconocedor alternativo (mejor con nombres y acentos), y auriculares/cancelación de eco perfecta: el autor los dejó para después.
- Voz neuronal: probar Qwen3-TTS (más natural en español) cambiando solo el servidor; Kokoro en MPS o partir la primera frase por comas para bajar el arranque de ~1 s.
- Distribución sin Xcode ni terminal (app firmada y notarizada, asistente de primera ejecución): pendiente de una cuenta de desarrollador de Apple.
- La interrupción por voz mientras Claude habla depende de la cancelación de eco; si se interrumpe a sí mismo, revisar el momento en que se desactiva el bypass.
