// Claude Voice - asistente de voz "hey claude" para macOS
// Escucha el micrófono, detecta la palabra de activación, transcribe, manda a Claude Code,
// habla la respuesta y muestra un widget flotante con el estado.

import AppKit
import AVFoundation
import CoreAudio
import Speech
import Carbon
import UserNotifications
import NaturalLanguage

// MARK: - Configuración

let homeDir = FileManager.default.homeDirectoryForCurrentUser
let baseDir = homeDir.appendingPathComponent("claude-voice")
let sessionFile = baseDir.appendingPathComponent(".session")
let logFile = baseDir.appendingPathComponent("voice.log")
let appLogFile = baseDir.appendingPathComponent("app.log")
let contextFile = baseDir.appendingPathComponent("contexto.md")
let vocabFile = baseDir.appendingPathComponent("vocabulario.txt")
let correctionsFile = baseDir.appendingPathComponent("correcciones.txt")
let triggerFile = baseDir.appendingPathComponent(".trigger")
let logoFile = baseDir.appendingPathComponent("logo.png")
let voiceName = "Paulina"
let micGain: Float = 1.0
let useEchoCancellation = true   // amplificación del micrófono (1 = sin cambio)
let debugText = UserDefaults.standard.bool(forKey: "debugTrace")
let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757

let claudeBin: String = {
    for p in ["\(homeDir.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return "claude"
}()

// Lista blanca: solo estos prefijos de comando, y escritura de archivos solo en Escritorio, Documentos y el contexto personal.
let allowedTools = [
    "Bash(open:*)", "Bash(osascript:*)", "Bash(say:*)", "Bash(screencapture:*)",
    "Bash(ps:*)", "Bash(top:*)", "Bash(df:*)", "Bash(du:*)", "Bash(pmset:*)", "Bash(uptime:*)", "Bash(date:*)", "Bash(cal:*)",
    "Bash(ls:*)", "Bash(find:*)", "Bash(mdfind:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(grep:*)", "Bash(wc:*)", "Bash(file:*)", "Bash(stat:*)",
    "Bash(system_profiler:*)", "Bash(sw_vers:*)", "Bash(networksetup -get*)", "Bash(ifconfig:*)", "Bash(ping -c:*)", "Bash(defaults read:*)",
    "Bash(mkdir:*)", "Bash(touch:*)", "Bash(cp:*)", "Bash(pbpaste:*)", "Bash(pbcopy:*)", "Bash(echo:*)", "Bash(printf:*)",
    "Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)",
    "Read", "Glob", "Grep",
    "Write(~/Desktop/**)", "Write(~/Documents/**)", "Edit(~/Desktop/**)", "Edit(~/Documents/**)", "Edit(~/claude-voice/contexto.md)", "Write(~/claude-voice/contexto.md)",
    "WebSearch", "WebFetch", "mcp__claude-in-chrome__*", "mcp__claude_ai_Gmail__*", "mcp__claude_ai_Google_Calendar__*",
    "Bash(~/claude-voice/tareas/calendario.sh:*)", "Bash(bash ~/claude-voice/tareas/calendario.sh:*)", "Bash(\(baseDir.path)/tareas/calendario.sh:*)",
    "Bash(~/claude-voice/tareas/calendario:*)", "Bash(\(baseDir.path)/tareas/calendario:*)",
    "Bash(~/claude-voice/tareas/mensajes.sh:*)", "Bash(bash ~/claude-voice/tareas/mensajes.sh:*)", "Bash(\(baseDir.path)/tareas/mensajes.sh:*)",
].joined(separator: ",")
// Lo que nunca puede hacer por voz, aunque se lo pidas
let disallowedTools = "Bash(rm:*),Bash(rm -rf:*),Bash(rmdir:*),Bash(srm:*),Bash(sudo:*),Bash(su:*),Bash(dd:*),Bash(mkfs:*),Bash(diskutil:*),Bash(shutdown:*),Bash(reboot:*),Bash(halt:*),Bash(launchctl:*),Bash(killall:*),Bash(pkill:*),Bash(kill:*),Bash(chmod:*),Bash(chown:*),Bash(defaults delete:*),Bash(git push:*),Bash(git reset:*),Bash(security:*),mcp__claude_ai_Gmail__send_message,mcp__claude_ai_Gmail__forward,mcp__claude_ai_Gmail__reply,mcp__claude_ai_Gmail__trash_message,mcp__claude_ai_Gmail__trash_thread,mcp__claude_ai_Gmail__delete_label,mcp__claude_ai_Gmail__mark_message_spam,mcp__claude_ai_Gmail__mark_thread_spam"

let baseSystemPrompt = """
Eres un asistente de voz en la Mac del usuario. Todo lo que recibes fue dictado por voz y tu respuesta será leída en voz alta.
Reglas:
- Responde SIEMPRE en el idioma en que te hablaron en esa orden (español o inglés), en 1 o 2 frases cortas, tono natural. Sin markdown, sin listas, sin código, sin URLs largas.
- Si te piden abrir una app usa: open -a "Nombre". Si te piden una página web usa: open -a "Google Chrome" "https://...".
- Si te piden hacer algo dentro de una página (buscar, leer, llenar), usa las herramientas de Chrome.
- Para acciones del sistema (volumen, música, etc.) usa osascript. Para preguntas sobre la Mac (procesos, CPU, memoria, disco, batería, red, archivos) usa comandos como ps, top -l 1, df, du, system_profiler, pmset, ls, find.
- Puedes crear y editar archivos solo en el Escritorio y en Documentos; nunca borrar archivos. Si una acción no está permitida, dilo en una frase en vez de buscar otra forma de hacerla.
- Para correo usa las herramientas de Gmail (buscar, leer, crear borradores; no puedes enviar). Para Google Calendar usa sus herramientas.
- Calendarios y Recordatorios de Apple: usa la herramienta \(baseDir.path)/tareas/calendario con Bash (rápida, EventKit). Si responde "sin permiso" usa \(baseDir.path)/tareas/calendario.sh (AppleScript, más lento) con los mismos subcomandos y pide al usuario activar Calendario para Claude Voice en Privacidad. Subcomandos: "calendarios"; "listar DESDE HASTA [calendario]" (uid, calendario, inicio, fin, título, uno por línea); "duplicados DESDE HASTA [calendario]" (grupos con mismo título, inicio y fin, y la línea UIDS_A_BORRAR con los sobrantes); "borrar UID..." (una serie repetitiva se borra entera); "crear \"título\" \"YYYY-MM-DD HH:MM\" \"YYYY-MM-DD HH:MM\" [calendario]"; "borrar-calendario \"nombre\"" (quita un calendario o suscripción entera; confirma siempre antes); "recordatorios [lista]", "recordatorio-crear \"texto\" [\"YYYY-MM-DD HH:MM\"] [lista]", "recordatorio-completar ID". Usa la herramienta, no escribas tu propio AppleScript. Fechas YYYY-MM-DD; si el usuario no dice rango, usa desde hace 3 meses hasta dentro de 12. Borrar eventos SÍ está permitido: si el usuario ya pidió borrar en la orden, hazlo y di cuántos borraste; si solo pidió buscar, di cuántos hay y pregunta si los borras. Antes de borrar más de 30 eventos, resume qué vas a borrar y pide confirmación. Si el script pide permiso de automatización, dile al usuario que acepte el aviso de Calendario. Si antes en esta conversación dijiste que no podías borrar eventos o calendarios, eso ya no aplica: ahora sí puedes con el script. Los eventos de un calendario suscrito (feed) no se pueden borrar uno a uno: ofrece quitar la suscripción entera con borrar-calendario.
- Mensajes y notificaciones: \(baseDir.path)/tareas/mensajes.sh notificaciones (lo que hay en el Centro de notificaciones) y mensajes.sh mensajes [N] [contacto] (últimos mensajes de Mensajes/iMessage; si falla, Claude Voice necesita Acceso total al disco). Resume lo importante en una o dos frases, sin leer números de teléfono.
- Memoria personal: sé proactivo. Cuando en la conversación aparezca un dato duradero del usuario (nombre, carrera o universidad, materias, trabajo, intereses, correos, personas cercanas, apps o sitios que usa, preferencias) y no esté ya en el contexto personal, agrégalo como UNA línea corta que empiece con "- " al final de \(contextFile.path) usando Edit. No guardes cosas pasajeras ni repitas lo que ya está. No hace falta anunciarlo salvo que el usuario te lo haya pedido.
- Habla como en una conversación: frases cortas, la primera frase debe ser útil por sí sola porque se lee en voz alta apenas la escribes.
- Ejecuta la acción directamente y confirma en una frase corta. No pidas confirmación salvo que sea destructivo.
- Si el dictado tiene errores obvios, interpreta la intención más probable usando el contexto personal.
- Es una conversación continua: si necesitas aclarar algo, pregunta en una frase y el usuario te responderá por voz.
"""

func systemPrompt() -> String {
    var s = baseSystemPrompt
    if let ctx = try? String(contentsOf: contextFile, encoding: .utf8), !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        s += "\n\nContexto personal del usuario. Tiene prioridad sobre cualquier interpretación literal: si el dictado se parece a una sigla o nombre de aquí, usa este significado y no adivines dominios:\n" + ctx
    }
    return s
}

func loadVocab() -> [String] {
    guard let t = try? String(contentsOf: vocabFile, encoding: .utf8) else { return ["Claude"] }
    return t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// Correcciones de dictado: "lo que oye | otra forma => lo que quisiste decir", una por línea.
/// Se aplican a la orden completa antes de enviarla, sin distinguir mayúsculas y solo sobre palabras completas.
func loadCorrections() -> [(NSRegularExpression, String)] {
    guard let t = try? String(contentsOf: correctionsFile, encoding: .utf8) else { return [] }
    var out: [(NSRegularExpression, String)] = []
    for raw in t.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        let sep = line.range(of: "=>") ?? line.range(of: "->")
        guard let sep else { continue }
        let right = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
        let alts = line[..<sep.lowerBound].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !alts.isEmpty, !right.isEmpty else { continue }
        let body = alts.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
        // Un dominio ("chef.com") vale aunque venga pegado a la palabra anterior ("abraschef.com"); el resto, solo palabras completas
        let left = alts.allSatisfy { $0.contains(".") } ? "" : "(?<![\\p{L}\\p{N}])"
        if let r = try? NSRegularExpression(pattern: "\(left)(?:\(body))(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) {
            out.append((r, right))
        }
    }
    return out
}

func applyCorrections(_ s: String) -> String {
    var out = s
    for (r, right) in loadCorrections() {
        out = r.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: NSRegularExpression.escapedTemplate(for: right))
    }
    return out
}

// MARK: - Memoria personal (contexto.md) revisable

/// Lectura y edición de contexto.md como lista de hechos ("- …"). Las líneas nuevas llevan fecha al final para poder
/// resumir lo aprendido cada semana; las antiguas sin fecha se muestran igual.
enum MemoryFile {
    static let dateTag = try! NSRegularExpression(pattern: #"\s*\((\d{4}-\d{2}-\d{2})\)\s*$"#)
    static func lines() -> [String] {
        ((try? String(contentsOf: contextFile, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    static func facts() -> [String] {
        lines().filter { $0.hasPrefix("- ") }.map { strip($0) }
    }
    static func strip(_ line: String) -> String {
        let t = String(line.dropFirst(2))
        return dateTag.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
    static func date(of line: String) -> String? {
        guard let m = dateTag.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (line as NSString).substring(with: m.range(at: 1))
    }
    static func append(_ fact: String) {
        let line = "- \(fact) (\(UsageStore.key()))\n"
        if let h = try? FileHandle(forWritingTo: contextFile) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: contextFile, atomically: true, encoding: .utf8) }
    }
    static func remove(lineIndex: Int) {
        var ls = lines(); guard ls.indices.contains(lineIndex) else { return }
        ls.remove(at: lineIndex)
        try? ls.joined(separator: "\n").write(to: contextFile, atomically: true, encoding: .utf8)
    }
    static func newSince(days: Int) -> [String] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return lines().filter { $0.hasPrefix("- ") }.compactMap { l in
            guard let d = date(of: l), let dd = f.date(from: d), dd >= from else { return nil }
            return strip(l)
        }
    }
}

// MARK: - Rutinas por voz

struct Routine: Codable {
    var id: String
    var text: String        // la orden que se ejecuta
    var hour: Int
    var minute: Int
    var days: [Int]         // 1 = domingo … 7 = sábado; vacío = todos los días
    var lastRun: String? = nil   // yyyy-MM-dd
    var whenText: String {
        let names = ["", "domingos", "lunes", "martes", "miércoles", "jueves", "viernes", "sábados"]
        let d = days.isEmpty ? "todos los días" : days.count == 5 && !days.contains(1) && !days.contains(7) ? "entre semana" : days.count == 2 && days.contains(1) && days.contains(7) ? "los fines de semana" : "los " + days.sorted().map { names[$0] }.joined(separator: " y ")
        return "\(d) a las \(hour):\(String(format: "%02d", minute))"
    }
}

/// "Cada mañana a las 8 dime el clima y mi agenda": órdenes programadas que se ejecutan por voz cuando el asistente está libre.
final class Routines {
    static let file = baseDir.appendingPathComponent("rutinas.json")
    private(set) var items: [Routine] = []
    var canFire: (() -> Bool)?
    var onFire: ((Routine) -> Void)?
    private var timer: Timer?

    init() {
        if let d = try? Data(contentsOf: Routines.file), let list = try? JSONDecoder().decode([Routine].self, from: d) { items = list }
        timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(items) { try? d.write(to: Routines.file, options: .atomic) }
    }
    func add(_ r: Routine) { items.append(r); save() }
    func remove(id: String) { items.removeAll { $0.id == id }; save() }

    /// Interpreta "cada mañana a las 8 y media dime el clima", "todos los lunes a las 9 revisa mi correo", "cada noche resume mi día".
    static func parse(_ n: String, original: String) -> Routine? {
        let ns = n as NSString
        let pat = #"^(?:cada|todos los|todas las|every)\s+(dia|dias|manana|mananas|noche|noches|tarde|tardes|lunes|martes|miercoles|jueves|viernes|sabado|sabados|domingo|domingos|dia entre semana|dias entre semana|fin de semana|fines de semana|day|morning|evening|night|afternoon|weekday|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?:\s+(?:a las|a la|at)\s+(\d{1,2})(?::(\d{2}))?(\s+y media|\s+y cuarto|:30|\s*pm|\s*am|\s+de la (?:manana|tarde|noche))*)?[,]?\s+(.+)$"#
        guard let m = rx(pat).firstMatch(in: n, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        let period = g(1)
        var hour = Int(g(2)) ?? -1, minute = Int(g(3)) ?? 0
        let mods = g(4)
        if mods.contains("y media") || mods.contains(":30") { minute = 30 }
        if mods.contains("y cuarto") { minute = 15 }
        if hour >= 0 && hour < 12 && (mods.contains("tarde") || mods.contains("noche") || mods.contains("pm")) { hour += 12 }
        if hour < 0 {
            hour = period.hasPrefix("noche") || period.hasPrefix("night") || period.hasPrefix("evening") ? 21 : period.hasPrefix("tarde") || period.hasPrefix("afternoon") ? 15 : 8
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let dayMap: [String: [Int]] = ["domingo": [1], "lunes": [2], "martes": [3], "miercoles": [4], "jueves": [5], "viernes": [6], "sabado": [7],
                                       "sunday": [1], "monday": [2], "tuesday": [3], "wednesday": [4], "thursday": [5], "friday": [6], "saturday": [7],
                                       "fin de semana": [1, 7], "weekend": [1, 7], "dia entre semana": [2, 3, 4, 5, 6], "weekday": [2, 3, 4, 5, 6]]
        var days: [Int] = []
        for (k, v) in dayMap where period.hasPrefix(k) { days = v }
        // El texto de la orden con acentos si las longitudes coinciden
        var text = g(5)
        if (normalize(original) as NSString).length == ns.length { text = (original as NSString).substring(with: m.range(at: 5)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.split(separator: " ").count >= 2 else { return nil }
        return Routine(id: UUID().uuidString, text: text, hour: hour, minute: minute, days: days)
    }

    private func check() {
        guard !items.isEmpty, canFire?() ?? true else { return }
        let now = Date(); let cal = Calendar.current
        let today = UsageStore.key(now)
        let h = cal.component(.hour, from: now), mi = cal.component(.minute, from: now), wd = cal.component(.weekday, from: now)
        for (i, r) in items.enumerated() where r.lastRun != today {
            guard r.days.isEmpty || r.days.contains(wd) else { continue }
            let due = h * 60 + mi, target = r.hour * 60 + r.minute
            // Ventana de 15 min por si el asistente estaba ocupado a la hora exacta
            guard due >= target, due <= target + 15 else { continue }
            items[i].lastRun = today
            save()
            onFire?(r)
            return
        }
    }
}

// MARK: - Uso (tokens y costo)

/// Contador persistente de tokens y costo por día y por modelo (~/claude-voice/uso.json).
/// El costo es el precio de lista de la API que reporta Claude Code; con una suscripción no se cobra aparte.
final class UsageStore {
    static let shared = UsageStore()
    static let file = baseDir.appendingPathComponent("uso.json")
    struct Bucket: Codable {
        var turns = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var cost = 0.0
        mutating func add(_ o: Bucket) { turns += o.turns; input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite; cost += o.cost }
        var tokens: Int { input + output + cacheRead + cacheWrite }
    }
    struct Day: Codable { var total = Bucket(); var models: [String: Bucket] = [:]; var kinds: [String: Bucket] = [:]; var local = 0 }
    private(set) var days: [String: Day] = [:]
    var onChange: (() -> Void)?

    private init() {
        if let d = try? Data(contentsOf: UsageStore.file), let v = try? JSONDecoder().decode([String: Day].self, from: d) { days = v }
    }

    static func key(_ date: Date = Date()) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }

    func add(model: String, kind: String = "Conversación", _ b: Bucket) {
        guard b.turns > 0 || b.tokens > 0 || b.cost > 0 else { return }
        let k = UsageStore.key()
        var day = days[k] ?? Day()
        day.total.add(b)
        var m = day.models[model] ?? Bucket(); m.add(b); day.models[model] = m
        var kb = day.kinds[kind] ?? Bucket(); kb.add(b); day.kinds[kind] = kb
        days[k] = day
        save()
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Orden resuelta sin modelo (hora, volumen, recordatorio…): cuenta como gratis.
    func countLocal() {
        let k = UsageStore.key()
        var day = days[k] ?? Day(); day.local += 1; days[k] = day
        save()
    }
    var monthLocal: Int { let p = String(UsageStore.key().prefix(7)); return days.filter { $0.key.hasPrefix(p) }.reduce(0) { $0 + $1.value.local } }
    var monthKinds: [String: Bucket] {
        let p = String(UsageStore.key().prefix(7)); var out: [String: Bucket] = [:]
        for (k, d) in days where k.hasPrefix(p) { for (kind, b) in d.kinds { var x = out[kind] ?? Bucket(); x.add(b); out[kind] = x } }
        return out
    }
    static var alertUSD: Double { UserDefaults.standard.double(forKey: "usageAlertUSD") }

    func reset() { days = [:]; save(); onChange?() }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(days) { try? d.write(to: UsageStore.file, options: .atomic) }
    }

    /// Suma de los días cuya clave cumple el filtro.
    func sum(where keep: (String) -> Bool) -> (Bucket, [String: Bucket]) {
        var t = Bucket(); var models: [String: Bucket] = [:]
        for (k, d) in days where keep(k) {
            t.add(d.total)
            for (m, b) in d.models { var x = models[m] ?? Bucket(); x.add(b); models[m] = x }
        }
        return (t, models)
    }
    var today: Bucket { sum { $0 == UsageStore.key() }.0 }
    var month: (Bucket, [String: Bucket]) { let p = String(UsageStore.key().prefix(7)); return sum { $0.hasPrefix(p) } }
    var total: (Bucket, [String: Bucket]) { sum { _ in true } }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.1f k", Double(n) / 1000) : "\(n)"
    }
    static func money(_ c: Double) -> String { c < 0.1 && c > 0 ? String(format: "$%.3f", c) : String(format: "$%.2f", c) }
    static func modelName(_ id: String) -> String {
        let l = id.lowercased()
        return l.contains("haiku") ? "Haiku" : l.contains("sonnet") ? "Sonnet" : l.contains("opus") ? "Opus" : l.contains("fable") ? "Fable" : id
    }
}

// MARK: - Elección de modelo

let modelsFile = baseDir.appendingPathComponent("modelos.txt")

func loadModelTiers() -> [String: String] {
    var tiers = ["simple": "haiku", "normal": "sonnet", "profundo": "default"]
    if let t = try? String(contentsOf: modelsFile, encoding: .utf8) {
        for line in t.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }
            let parts = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[1].isEmpty { tiers[parts[0]] = parts[1] }
        }
    }
    return tiers
}

func saveModelTiers(_ tiers: [String: String]) {
    let text = """
    # Qué modelo usa Claude Voice según la orden. Alias válidos: haiku, sonnet, opus, default
    # simple  = preguntas cortas (hora, fecha, cuentas, abrir una app o página)
    # normal  = todo lo demás (Chrome, revisar páginas, tareas de varios pasos)
    # profundo = cuando dices "piensa bien", "a fondo" o "con calma"
    simple=\(tiers["simple"] ?? "haiku")
    normal=\(tiers["normal"] ?? "sonnet")
    profundo=\(tiers["profundo"] ?? "default")

    """
    try? text.write(to: modelsFile, atomically: true, encoding: .utf8)
}

let deepRegex = try! NSRegularExpression(pattern: #"\b(piensa bien|pensalo bien|a fondo|con calma|modelo grande|analiza bien|detalladamente|think hard|think carefully|in depth|take your time|big model)\b"#)
let complexRegex = try! NSRegularExpression(pattern: #"\b(revisa|revisar|busca en|buscame|lee|leer|leeme|tareas|tarea|compara|analiza|resume|resumen|escribe|redacta|llena|rellena|correo|correos|email|calendario|agenda|canvas|investiga|averigua|encuentra|descarga|instala|configura|crea|genera|programa|codigo|proyecto|documento|archivo|carpeta|traduce todo|explica|video|videos|pelicula|serie|noticias|precio|precios|compra|reserva)\b"#)
let simpleRegex = try! NSRegularExpression(pattern: #"^(que hora|que dia|que fecha|cuanto es|cuantos? |cuanta |abre |abrir |pon |quita |sube |baja |silencia|mutea|cierra |cerrar |como se dice|que significa|traduce |define |cuentame un chiste|hola|gracias|repite|que dijiste|dime la hora|que tiempo|que clima|cuando es|what time|what day|what's the date|what is the date|how much is|how many|open |launch |play |turn |mute|close |quit |how do you say|what does .* mean|translate |define |tell me a joke|hello|hi |thanks|repeat|what did you say)"#)

/// Devuelve (alias del modelo, nombre para mostrar) según la orden.
func chooseModel(for cmd: String) -> (String?, String) {
    let tiers = loadModelTiers()
    let n = normalize(cmd).trimmingCharacters(in: .punctuationCharacters)
    let words = n.split(separator: " ").count
    let tier: String
    if matches(deepRegex, n) { tier = "profundo" }
    else if matches(complexRegex, n) { tier = "normal" }
    else if matches(simpleRegex, n) && words <= 10 { tier = "simple" }
    else if words <= 5 { tier = "simple" }
    else { tier = "normal" }
    let alias = tiers[tier] ?? "default"
    let names = ["haiku": "Haiku", "sonnet": "Sonnet", "opus": "Opus", "default": "Fable"]
    return (alias == "default" ? nil : alias, names[alias] ?? alias)
}

// MARK: - Idioma

let spanishHints: Set<String> = ["el","la","los","las","de","del","que","y","en","un","una","para","por","con","es","esta","este","como","cuanto","cuantos","cual","donde","cuando","hola","gracias","abre","abrir","pon","busca","buscame","dime","cuentame","recuerdame","avisame","revisa","lee","cierra","sube","baja","quiero","puedes","me","mi","mis","tu","tus","hoy","manana","ahora","si","no","por","favor","tengo","hay","hazme","ponme","dame","ve","vete","llama","escribe","crea","explica","traduce","cuál","qué","cómo","también","luego","listo","claro"]
let englishHints: Set<String> = ["the","a","an","to","of","and","in","on","is","it","for","with","you","my","me","i","im","can","could","would","do","does","what","how","much","many","which","where","when","who","why","hello","hi","hey","thanks","thank","open","play","search","tell","show","remind","check","read","close","turn","up","down","set","timer","please","yes","no","today","tomorrow","now","want","need","have","there","are","this","that","write","create","explain","translate","find","look","give","make","start","stop","call","send","go","get","put","time","weather","news","email","calendar","video","music","song"]

/// Puntúa qué tan español o inglés parece un texto (positivo = español, negativo = inglés).
func languageScore(_ text: String) -> Int {
    let words = normalize(text).split(whereSeparator: { !$0.isLetter }).map(String.init)
    var es = 0, en = 0
    for w in words { if spanishHints.contains(w) { es += 1 }; if englishHints.contains(w) { en += 1 } }
    return es - en
}

/// Idioma de un texto ya generado (para elegir la voz que lo lee).
func textLanguage(_ text: String) -> String {
    let r = NLLanguageRecognizer()
    r.languageConstraints = [.spanish, .english]
    r.processString(text)
    if let l = r.dominantLanguage { return l == .english ? "en" : "es" }
    return languageScore(text) < 0 ? "en" : "es"
}

// MARK: - Utilidades

/// El reconocedor de español escribe el inglés con Cada Palabra En Mayúscula; lo devolvemos a frase normal.
func fixTitleCase(_ text: String) -> String {
    let words = text.split(separator: " ").map(String.init)
    guard words.count >= 3 else { return text }
    let titled = words.filter { w in
        guard let f = w.first, f.isUppercase else { return false }
        return w.dropFirst().allSatisfy { !$0.isUppercase }
    }.count
    guard Double(titled) >= Double(words.count) * 0.7 else { return text }
    var fixed = words.map { $0.lowercased() }
    fixed = fixed.map { $0 == "i" ? "I" : ($0.hasPrefix("i'") ? "I" + $0.dropFirst() : $0) }
    var out = fixed.joined(separator: " ")
    if let f = out.first { out = String(f).uppercased() + out.dropFirst() }
    return out
}

/// Mata procesos de Claude Code que quedaron huérfanos de una instancia anterior de la app (padre = launchd).
func killOrphanClaudeProcesses() {
    let out = shell("/bin/ps", ["-eo", "pid=,ppid=,command="])
    for line in out.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
        let cmd = String(parts[2])
        guard ppid == 1, cmd.contains("claude"), cmd.contains("--input-format stream-json"), cmd.contains("--include-partial-messages"), cmd.contains("--chrome") else { continue }
        kill(pid, SIGTERM)
        logApp("Terminé un proceso de Claude huérfano (pid \(pid))")
    }
}

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

func timestamp() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
}

func appendLine(_ file: URL, _ s: String) {
    let line = "[\(timestamp())] \(s)\n"
    if let h = try? FileHandle(forWritingTo: file) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: file, atomically: true, encoding: .utf8)
    }
}
func logConv(_ s: String) { appendLine(logFile, s) }
func logApp(_ s: String) { appendLine(appLogFile, s) }

/// Recorta app.log al arrancar para que no crezca sin límite (conserva la última parte).
func rotateAppLog(maxBytes: Int = 512 * 1024, keep: Int = 256 * 1024) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: appLogFile.path),
          let size = attrs[.size] as? Int, size > maxBytes,
          let data = try? Data(contentsOf: appLogFile) else { return }
    let tail = data.suffix(keep)
    if let nl = tail.firstIndex(of: 10) { try? Data(tail[(nl + 1)...]).write(to: appLogFile) }
}

func normalize(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}

func readSession() -> String? {
    guard let s = try? String(contentsOf: sessionFile, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}
func writeSession(_ id: String) { try? id.write(to: sessionFile, atomically: true, encoding: .utf8) }
let sessionTimeFile = baseDir.appendingPathComponent(".session_time")
let sessionMaxIdle: TimeInterval = 20 * 60   // tras 20 min sin hablar, conversación nueva
func touchSessionTime() { try? String(Date().timeIntervalSince1970).write(to: sessionTimeFile, atomically: true, encoding: .utf8) }
func sessionIsStale() -> Bool {
    guard let t = try? String(contentsOf: sessionTimeFile, encoding: .utf8), let ts = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return Date().timeIntervalSince1970 - ts > sessionMaxIdle
}
func clearSession() { try? FileManager.default.removeItem(at: sessionFile) }

let wakeRegex = try! NSRegularExpression(pattern: #"(?:^|[^a-z])(?:hey|ey|hei|oye|hola|ok|okey|okay)[ ,.]*(?:icloud|claude|cloud|clod|clot|claud|clau|klaud|klod|clout|claudio|claudia|klaus)(?:[^a-z]|$)"#)
// El reconocedor a veces separa "Hey" y "Cloud" en trozos distintos: un trozo que empieza por el nombre también activa
let bareWakeRegex = try! NSRegularExpression(pattern: #"^[ ,.]*(?:icloud|claude|cloud|clau|klaud|klaus)(?:[^a-z]|$)"#)
// Cierre: solo palabras de despedida/agradecimiento, y al menos una "fuerte"
let endRegex = try! NSRegularExpression(pattern: #"^(?:(?:ok|okay|okey|bueno|listo|gracias|muchas|claude|clau|cloud|suficiente|eso|es|todo|nada|mas|adios|perfecto|vale|genial|chao|bye|hasta|luego|thanks|thank|you|that's|thats|that|all|done|goodbye|enough|good|great|perfect|cool|alright|it|is)[ ,.!']*)+$"#)
let endStrongRegex = try! NSRegularExpression(pattern: #"\b(listo|gracias|suficiente|adios|chao|bye|perfecto|vale|genial|luego|todo|nada|thanks|thank|done|goodbye|enough|okay|ok|all|perfect|great|cool)\b"#)
let onlyStopRegex = try! NSRegularExpression(pattern: #"^(?:(?:para|stop|espera|alto|basta|callate|silencio|wait|quiet|hold on|ya)[ ,.!]*)+$"#)
let newConvRegex = try! NSRegularExpression(pattern: #"^(nueva conversacion|empezar de nuevo|reinicia|reiniciar|borra la conversacion|new conversation|start over|reset)"#)
let memoryRegex = try! NSRegularExpression(pattern: #"^(recuerda|recuerdate|acuerdate|apunta|anota|ten en cuenta|guarda en memoria|memoriza|remember|keep in mind|note)( que | esto:? | that | this:? | )(.+)$"#)
let screenRegex = try! NSRegularExpression(pattern: #"\b(pantalla|en mi pantalla|lo que veo|esto que veo|este error|esta grafica|esta imagen|esta ventana|screen|on my screen|what i'm looking at|this error|this chart|this window)\b"#)
let clipboardRegex = try! NSRegularExpression(pattern: #"\b(portapapeles|lo que copie|lo copiado|clipboard|what i copied)\b"#)
let selectionRegex = try! NSRegularExpression(pattern: #"\b(lo seleccionado|el texto seleccionado|la seleccion|selected text|the selection|what i selected|what's selected)\b"#)
let typeRegex = try! NSRegularExpression(pattern: #"^(escribe esto|escribe lo siguiente|teclea|dicta|type this|type the following|type)[:,]?\s+(.+)$"#)
let eyesRegex = try! NSRegularExpression(pattern: #"^(que es esto|que es eso|que ves|que estas viendo|que estoy viendo|que dice (aqui|esto|ahi|eso)|explicame esto|explica esto|lee esto|leeme esto|que hay aqui|resume esto|traduce esto|what is this|what's this|what do you see|what does this say|explain this|read this|summarize this|translate this)\b"#)
let regionRegex = try! NSRegularExpression(pattern: #"\b(esta zona|esta parte|esta area|una zona|la zona que|marco|marcar|te marco|selecciono|voy a seleccionar|this area|this part|this region|let me mark|i'll select)\b"#)
let historyRegex = try! NSRegularExpression(pattern: #"^(?:que|dime que|recuerdas que|recuerdame que)?\s*(?:me dijiste|dijiste|me contaste|contaste|respondiste|me respondiste|hablamos|te pregunte|me recomendaste|me explicaste|what did you tell me|what did you say|what did we talk about|what did i ask)\b(?:.*?)\b(?:sobre|de|acerca de|about|regarding)\s+(.+)$"#)
let muteOnRegex = try! NSRegularExpression(pattern: #"^(silencia(te)?( la voz)?|sin voz|mutea(te)?|mute( yourself)?|quita(te)? (el sonido|la voz)|no hables( mas)?|solo escribe|modo (silencio|silencioso|texto)|no voice|text only|stop talking)\b"#)
let muteOffRegex = try! NSRegularExpression(pattern: #"^(con voz|activa (la )?voz|vuelve a hablar|habla de nuevo|quita el silencio|desmutea(te)?|unmute|voice on|talk again|speak again)\b"#)
let stopRegex = try! NSRegularExpression(pattern: #"\b(para|stop|alto|callate|basta|silencio|espera|ya|wait|quiet|shut up|hold on|enough)\b"#)

func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
}

/// Devuelve el texto dicho después de la última palabra de activación, o nil si no la hay.
func commandAfterWake(_ raw: String) -> String? {
    let norm = normalize(raw)
    let ns = norm as NSString
    guard let m = wakeRegex.matches(in: norm, range: NSRange(location: 0, length: ns.length)).last
            ?? bareWakeRegex.firstMatch(in: norm, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let end = min(m.range.location + m.range.length, ns.length)
    let source: NSString = ((raw as NSString).length == ns.length) ? (raw as NSString) : ns
    return source.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
}

private var regexCache: [String: NSRegularExpression] = [:]
/// Regex compilada una sola vez por patrón.
func rx(_ pattern: String) -> NSRegularExpression {
    if let r = regexCache[pattern] { return r }
    let r = try! NSRegularExpression(pattern: pattern)
    regexCache[pattern] = r
    return r
}

func toolLabel(_ name: String, _ input: [String: Any]) -> String {
    if name == "Bash" {
        let cmd = input["command"] as? String ?? ""
        if cmd.hasPrefix("open") {
            if let m = rx(#"-a\s+"?([^"]+?)"?(?:\s|$)"#).firstMatch(in: cmd, range: NSRange(location: 0, length: (cmd as NSString).length)) {
                let app = (cmd as NSString).substring(with: m.range(at: 1))
                return cmd.contains("http") ? "Abriendo página en \(app)…" : "Abriendo \(app)…"
            }
            return "Abriendo…"
        }
        if cmd.hasPrefix("osascript") { return "Acción del sistema…" }
        return "Ejecutando comando…"
    }
    if name.hasPrefix("mcp__claude-in-chrome__") {
        let t = name.replacingOccurrences(of: "mcp__claude-in-chrome__", with: "")
        switch t {
        case "navigate":
            if let u = input["url"] as? String, let host = URL(string: u)?.host { return "Abriendo \(host)…" }
            return "Navegando en Chrome…"
        case "read_page", "get_page_text": return "Leyendo la página…"
        case "find": return "Buscando en la página…"
        case "form_input": return "Llenando formulario…"
        case "tabs_create_mcp": return "Abriendo pestaña…"
        default: return "Usando Chrome…"
        }
    }
    if name.hasPrefix("mcp__claude_ai_Gmail__") { return "Revisando tu correo…" }
    if name.hasPrefix("mcp__claude_ai_Google_Calendar__") { return "Revisando tu calendario…" }
    if name == "Edit" || name == "Write" {
        if let path = input["file_path"] as? String, path.hasSuffix("contexto.md") { return "Guardando en memoria…" }
        return "Escribiendo archivo…"
    }
    if name == "Read" || name == "Glob" || name == "Grep" { return "Leyendo archivos…" }
    if name == "WebSearch" { return "Buscando en internet…" }
    if name == "WebFetch" { return "Consultando una web…" }
    return "Trabajando…"
}

// MARK: - Recordatorios y temporizadores

struct Reminder: Codable {
    var id: String
    var text: String
    var fire: TimeInterval
}

final class Reminders {
    private let file = baseDir.appendingPathComponent("recordatorios.json")
    private(set) var items: [Reminder] = []
    private var timer: Timer?
    var canFire: (() -> Bool)?
    var onFire: ((Reminder) -> Void)?

    init() {
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Reminder].self, from: d) { items = list }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: file) }
    }
    func add(text: String, at date: Date) {
        items.append(Reminder(id: UUID().uuidString, text: text, fire: date.timeIntervalSince1970))
        save()
    }
    private func check() {
        guard canFire?() ?? true else { return }
        let now = Date().timeIntervalSince1970
        guard let due = items.first(where: { $0.fire <= now }) else { return }
        items.removeAll { $0.id == due.id }
        save()
        onFire?(due)
    }
}

let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "half": 30, "a": 1, "an": 1, "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "veinte": 20, "veinticinco": 25, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "media": 30]

func parseNumber(_ w: String) -> Int? { Int(w) ?? numberWords[w] }

/// Interpreta "recuérdame en 20 minutos sacar la ropa", "temporizador de 5 minutos", "avísame a las 3 y media tomar agua".
/// Devuelve (cuándo, texto, descripción hablada) o nil.
func parseReminder(_ n: String) -> (Date, String, String)? {
    if let r = parseReminderEnglish(n) { return r }
    let ns = n as NSString
    func m(_ pattern: String) -> NSTextCheckingResult? {
        rx(pattern).firstMatch(in: n, range: NSRange(location: 0, length: ns.length))
    }
    func g(_ r: NSTextCheckingResult, _ i: Int) -> String { r.range(at: i).location == NSNotFound ? "" : ns.substring(with: r.range(at: i)) }
    let lead = #"^(?:recuerdame|recuerda|avisame|ponme un recordatorio|pon un recordatorio|pon una alarma|ponme una alarma|alarma|recordatorio)(?: que| de| para)?\s*"#
    let dur = #"(?:en|dentro de|por|de)\s+(\S+)\s*(?:y media)?\s+(segundos?|minutos?|min|horas?|hora)"#
    // "... en N minutos <texto>"  o  "... <texto> en N minutos"
    if let r = m(lead + dur + #"\s*(?:que|de|para)?\s*(.*)$"#) ?? m(lead + #"(.*?)\s+"# + dur + "$") {
        var numStr: String, unit: String, text: String
        if parseNumber(g(r, 1)) != nil { numStr = g(r, 1); unit = g(r, 2); text = g(r, 3) } else { text = g(r, 1); numStr = g(r, 2); unit = g(r, 3) }
        guard let num = parseNumber(numStr) else { return nil }
        let secs: Double = unit.hasPrefix("seg") ? Double(num) : unit.hasPrefix("hora") ? Double(num) * 3600 : Double(num) * 60
        let extra: Double = n.contains("y media") && unit.hasPrefix("hora") ? 1800 : 0
        let when = Date().addingTimeInterval(secs + extra)
        let unitName = unit.hasPrefix("seg") ? (num == 1 ? "segundo" : "segundos") : unit.hasPrefix("hora") ? (num == 1 ? "hora" : "horas") : (num == 1 ? "minuto" : "minutos")
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (when, t.isEmpty ? "Recordatorio" : t, "Listo, te aviso en \(num) \(unitName)\(extra > 0 ? " y media" : "").")
    }
    // temporizador
    if let r = m(#"^(?:pon|ponme|inicia|crea|activa)?\s*(?:un |una )?(?:temporizador|timer|cronometro|cuenta regresiva)\s+(?:de|por|para)\s+(\S+)\s+(segundos?|minutos?|min|horas?|hora)"#) {
        guard let num = parseNumber(g(r, 1)) else { return nil }
        let unit = g(r, 2)
        let secs: Double = unit.hasPrefix("seg") ? Double(num) : unit.hasPrefix("hora") ? Double(num) * 3600 : Double(num) * 60
        let unitName = unit.hasPrefix("seg") ? "segundos" : unit.hasPrefix("hora") ? "horas" : "minutos"
        return (Date().addingTimeInterval(secs), "Se acabó el tiempo", "Listo, temporizador de \(num) \(unitName).")
    }
    // a las H[:MM] [de la mañana/tarde/noche] <texto>
    if let r = m(lead + #"(.*?)\s*a las?\s+(\d{1,2}|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce)(?::(\d{2})| y media| y cuarto)?(?: de la (manana|tarde|noche))?\s*(.*)$"#) {
        guard var hour = parseNumber(g(r, 2)) else { return nil }
        var minute = Int(g(r, 3)) ?? 0
        let whole = g(r, 0)
        if whole.contains("y media") { minute = 30 } else if whole.contains("y cuarto") { minute = 15 }
        let period = g(r, 4)
        if (period == "tarde" || period == "noche") && hour < 12 { hour += 12 }
        if period == "noche" && hour == 12 { hour = 0 }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard var when = Calendar.current.date(from: comps) else { return nil }
        if when < Date() {
            if period.isEmpty && hour < 12, let pm = Calendar.current.date(byAdding: .hour, value: 12, to: when), pm > Date() { when = pm }
            else { when = Calendar.current.date(byAdding: .day, value: 1, to: when) ?? when }
        }
        let text = (g(r, 1) + " " + g(r, 5)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let f = DateFormatter(); f.dateFormat = "h:mm"; f.locale = Locale(identifier: "es_MX")
        return (when, text.isEmpty ? "Recordatorio" : text, "Listo, te aviso a las \(f.string(from: when)).")
    }
    return nil
}

func parseReminderEnglish(_ n: String) -> (Date, String, String)? {
    let ns = n as NSString
    func m(_ pattern: String) -> NSTextCheckingResult? {
        rx(pattern).firstMatch(in: n, range: NSRange(location: 0, length: ns.length))
    }
    func g(_ r: NSTextCheckingResult, _ i: Int) -> String { r.range(at: i).location == NSNotFound ? "" : ns.substring(with: r.range(at: i)) }
    func secs(_ num: Int, _ unit: String) -> (Double, String) {
        if unit.hasPrefix("sec") { return (Double(num), num == 1 ? "second" : "seconds") }
        if unit.hasPrefix("hour") { return (Double(num) * 3600, num == 1 ? "hour" : "hours") }
        return (Double(num) * 60, num == 1 ? "minute" : "minutes")
    }
    // "remind me in 20 minutes to take out the laundry" / "remind me to call mom in 5 minutes"
    if let r = m(#"^(?:remind me|set a reminder|wake me up|alert me)(?: to| that)?\s*(.*?)\s*in\s+(\S+)\s+(seconds?|minutes?|mins?|hours?)\s*(?:to|that)?\s*(.*)$"#) {
        guard let num = parseNumber(g(r, 2)) else { return nil }
        let (sec, name) = secs(num, g(r, 3))
        let text = (g(r, 1) + " " + g(r, 4)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (Date().addingTimeInterval(sec), text.isEmpty ? "Reminder" : text, "Okay, I'll remind you in \(num) \(name).")
    }
    // "set a timer for 10 minutes"
    if let r = m(#"^(?:set|start)?\s*(?:a|an)?\s*(?:timer|countdown)\s+(?:for|of)\s+(\S+)\s+(seconds?|minutes?|mins?|hours?)"#) {
        guard let num = parseNumber(g(r, 1)) else { return nil }
        let (sec, name) = secs(num, g(r, 2))
        return (Date().addingTimeInterval(sec), "Time's up", "Okay, timer set for \(num) \(name).")
    }
    return nil
}

// MARK: - Control de medios (pausa lo que esté sonando, como Siri)

final class MediaControl {
    private typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias SendCommand = @convention(c) (Int32, UnsafeRawPointer?) -> Bool
    private var getIsPlaying: GetIsPlaying?
    private var sendCommand: SendCommand?
    private var pausedByUs = false

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
            logApp("MediaRemote no disponible"); return
        }
        if let p = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") { getIsPlaying = unsafeBitCast(p, to: GetIsPlaying.self) }
        if let p = dlsym(h, "MRMediaRemoteSendCommand") { sendCommand = unsafeBitCast(p, to: SendCommand.self) }
    }

    func pauseIfPlaying() {
        guard let getIsPlaying, let sendCommand, !pausedByUs else { return }
        getIsPlaying(.main) { [weak self] playing in
            guard let self, playing, !self.pausedByUs else { return }
            _ = sendCommand(1, nil) // kMRPause
            self.pausedByUs = true
            logApp("Pausé el audio que estaba sonando")
        }
    }

    func resumeIfPaused() {
        guard pausedByUs, let sendCommand else { return }
        _ = sendCommand(0, nil) // kMRPlay
        pausedByUs = false
        logApp("Reanudé el audio")
    }
}

// MARK: - Logo animado

final class LogoView: NSView {
    enum Mode { case idle, listening, thinking, speaking }
    var mode: Mode = .idle
    var level: CGFloat = 0
    /// Tarea en curso: anillo de progreso (0…1) o anillo girando si aún no hay pasos; en espera de confirmación, anillo azul latiendo.
    var taskProgress: Double? = nil { didSet { needsDisplay = true } }
    var taskBusy = false { didSet { needsDisplay = true } }
    var attention = false { didSet { needsDisplay = true } }
    private var phase: CGFloat = 0
    private var timer: Timer?
    private let image = NSImage(contentsOf: logoFile)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let w = self.window, w.isVisible, w.alphaValue > 0 else { return }
            self.phase += 0.09
            self.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.width
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var scale: CGFloat = 1, rotation: CGFloat = 0
        switch mode {
        case .idle: scale = 0.9
        case .listening: scale = min(1.25, 0.9 + 0.06 * sin(phase) + 0.5 * level)
        case .thinking: rotation = phase * 0.9; scale = 0.92
        case .speaking: scale = 0.95 + 0.06 * sin(phase * 2.2)
        }
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        if let image {
            image.draw(in: bounds.insetBy(dx: size * 0.1, dy: size * 0.1))
        } else {
            drawStarburst(ctx, c, size)
        }
        ctx.restoreGState()
        drawTaskRing(ctx, c, size)
    }

    /// Anillo alrededor del logo: progreso de la tarea, giro si no hay pasos, o azul latiendo si espera tu "sí".
    private func drawTaskRing(_ ctx: CGContext, _ c: CGPoint, _ size: CGFloat) {
        guard attention || taskBusy || taskProgress != nil else { return }
        let r = size * 0.47
        let width = max(2, size * 0.055)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        let top = CGFloat.pi / 2
        if attention {
            let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase * 1.6))
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(pulse).cgColor)
            ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
            return
        }
        ctx.setStrokeColor(claudeOrange.withAlphaComponent(0.22).cgColor)
        ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(claudeOrange.cgColor)
        if let p = taskProgress, p > 0 {
            ctx.addArc(center: c, radius: r, startAngle: top, endAngle: top - CGFloat(min(1, p)) * 2 * .pi, clockwise: true)
        } else {
            let a = -phase * 1.5
            ctx.addArc(center: c, radius: r, startAngle: a, endAngle: a - 0.9, clockwise: true)
        }
        ctx.strokePath()
    }

    private func drawStarburst(_ ctx: CGContext, _ c: CGPoint, _ size: CGFloat) {
        ctx.setStrokeColor(claudeOrange.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(size * 0.105)
        let lengths: [CGFloat] = [1.0, 0.66, 0.9, 0.58, 1.0, 0.7, 0.86, 0.6, 0.98, 0.68, 0.9, 0.62]
        let r = size * 0.43
        let inner = r * 0.16
        for (i, l) in lengths.enumerated() {
            let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi + 0.2
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * r * l, y: c.y + sin(a) * r * l))
        }
        ctx.strokePath()
    }
}

// MARK: - Widget flotante

/// Máscara redondeada para NSVisualEffectView (el fondo translúcido no respeta cornerRadius de la capa).
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}

final class ClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Botón que arrastra la ventana si mueves el mouse, o dispara su acción si solo haces clic.
final class DragOrTapButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let start = event.locationInWindow
        var dragged = false
        while let e = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseDragged {
                if hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 {
                    dragged = true
                    win.performDrag(with: e)
                    break
                }
            } else {
                break
            }
        }
        if !dragged, let a = action { NSApp.sendAction(a, to: target, from: self) }
    }
}

final class Overlay: NSObject {
    let panel: NSPanel
    let logo: LogoView
    private let title = NSTextField(labelWithString: "")
    private let scroll = NSScrollView(frame: .zero)
    private let body = NSTextView(frame: .zero)
    private var bodyText = ""
    private let stopButton = ClickButton(frame: .zero)
    private let pauseButton = ClickButton(frame: .zero)
    private let muteButton = ClickButton(frame: .zero)
    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onMute: (() -> Void)?

    override init() {
        let w: CGFloat = 520, h: CGFloat = 156
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 30
        effect.layer?.masksToBounds = true
        effect.maskImage = roundedMask(radius: 30)
        effect.layer?.borderWidth = 0.6
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = effect

        logo = LogoView(frame: NSRect(x: 22, y: (h - 92) / 2, width: 92, height: 92))
        effect.addSubview(logo)

        title.frame = NSRect(x: 132, y: h - 44, width: w - 220, height: 24)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        effect.addSubview(title)

        // Área de texto con ajuste de líneas y desplazamiento automático
        scroll.frame = NSRect(x: 132, y: 14, width: w - 154, height: 96)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.wantsLayer = true
        let fade = CAGradientLayer()
        fade.frame = scroll.bounds
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.78, 1]
        scroll.layer?.mask = fade

        body.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height)
        body.isEditable = false
        body.isSelectable = false
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 2)
        body.textContainer?.lineFragmentPadding = 0
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        scroll.documentView = body
        effect.addSubview(scroll)

        stopButton.frame = NSRect(x: w - 46, y: h - 46, width: 30, height: 30)
        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.imagePosition = .imageOnly
        stopButton.toolTip = "Interrumpir"
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Interrumpir") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            stopButton.image = img.withSymbolConfiguration(cfg)
            stopButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        } else {
            stopButton.title = "✕"
        }
        effect.addSubview(stopButton)

        pauseButton.frame = NSRect(x: w - 82, y: h - 46, width: 30, height: 30)
        pauseButton.isBordered = false
        pauseButton.bezelStyle = .regularSquare
        pauseButton.imagePosition = .imageOnly
        pauseButton.toolTip = "Pausar"
        pauseButton.isHidden = true
        if let img = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Interrumpir") {
            pauseButton.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        } else { pauseButton.title = "■" }
        effect.addSubview(pauseButton)

        muteButton.frame = NSRect(x: w - 118, y: h - 46, width: 30, height: 30)
        muteButton.isBordered = false
        muteButton.bezelStyle = .regularSquare
        muteButton.imagePosition = .imageOnly
        effect.addSubview(muteButton)

        tapButton.isBordered = false
        tapButton.title = ""
        tapButton.isHidden = true
        tapButton.toolTip = "Hablar con Claude"
        effect.addSubview(tapButton)

        panel.alphaValue = 0
        super.init()
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        muteButton.target = self
        muteButton.action = #selector(mutePressed)
        setMuted(UserDefaults.standard.bool(forKey: "mutedVoice"))
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed)
        tapButton.target = self
        tapButton.action = #selector(tapped)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in self?.savePosition() }
        applyTheme()
    }

    @objc private func stopPressed() { onStop?() }
    @objc private func mutePressed() { onMute?() }

    /// Ícono del botón de silencio: altavoz normal o tachado.
    func setMuted(_ muted: Bool) {
        muteButton.toolTip = muted ? "Activar la voz" : "Silenciar la voz (sigue escribiendo)"
        let name = muted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: muteButton.toolTip) {
            muteButton.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        } else { muteButton.title = muted ? "🔇" : "🔊" }
        muteButton.contentTintColor = muted ? NSColor.systemOrange.withAlphaComponent(0.9) : fg.withAlphaComponent(0.6)
    }
    @objc private func pausePressed() { onPause?() }

    func showPause(_ show: Bool) { pauseButton.isHidden = !show || isCompact }

    private func position() {
        programmaticMove = true
        defer { programmaticMove = false }
        if let saved = UserDefaults.standard.array(forKey: "widgetCorner") as? [CGFloat], saved.count == 2 {
            let origin = NSPoint(x: saved[0] - panel.frame.width, y: saved[1])
            let rect = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { panel.setFrameOrigin(origin); return }
        }
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 18, y: f.minY + 18))
    }

    private var hideWork: DispatchWorkItem?

    var isHovered: Bool {
        panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
    }

    func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Si el usuario tiene el mouse encima (está leyendo), espera un poco más
            if self.isHovered { self.hide(after: 2); return }
            self.hide()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func show() {
        hideWork?.cancel(); hideWork = nil
        if !panel.isVisible { position() }
        expand()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        if showsIndicator {
            if !panel.isVisible { position(); panel.orderFrontRegardless() }
            collapse()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private var lastSpoken: NSRange? = nil
    private let fullSize = NSSize(width: 520, height: 156)
    private let compactSize: CGFloat = 54
    private(set) var isCompact = false
    private var programmaticMove = false
    private let tapButton = DragOrTapButton(frame: .zero)
    var onTap: (() -> Void)?
    var isLight: Bool { UserDefaults.standard.bool(forKey: "lightTheme") }
    var showsIndicator: Bool { UserDefaults.standard.object(forKey: "idleIndicator") == nil ? true : UserDefaults.standard.bool(forKey: "idleIndicator") }
    private var effectView: NSVisualEffectView { panel.contentView as! NSVisualEffectView }
    private var fg: NSColor { isLight ? NSColor.black : NSColor.white }

    func applyTheme() {
        let e = effectView
        e.material = isLight ? .popover : .hudWindow
        e.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        e.layer?.borderColor = (isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.14).cgColor
        title.textColor = fg
        stopButton.contentTintColor = fg.withAlphaComponent(0.6)
        pauseButton.contentTintColor = fg.withAlphaComponent(0.6)
        setMuted(UserDefaults.standard.bool(forKey: "mutedVoice"))
        render(spoken: lastSpoken, live: false)
    }

    /// Reduce el widget a un círculo con el logo (indicador de que está activo).
    func collapse() {
        guard !isCompact else { return }
        isCompact = true
        hideWork?.cancel(); hideWork = nil
        let f = panel.frame
        let target = NSRect(x: f.maxX - compactSize, y: f.minY, width: compactSize, height: compactSize)
        // 1) el texto se desvanece
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            title.animator().alphaValue = 0
            scroll.animator().alphaValue = 0
            stopButton.animator().alphaValue = 0
            pauseButton.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isCompact else { return }
            self.pauseButton.alphaValue = 1
            self.title.isHidden = true; self.scroll.isHidden = true; self.stopButton.isHidden = true; self.pauseButton.isHidden = true; self.muteButton.isHidden = true
            self.title.alphaValue = 1; self.scroll.alphaValue = 1; self.stopButton.alphaValue = 1
            self.effectView.layer?.cornerRadius = self.compactSize / 2
            self.effectView.maskImage = roundedMask(radius: self.compactSize / 2)
            self.tapButton.frame = NSRect(x: 0, y: 0, width: self.compactSize, height: self.compactSize)
            self.tapButton.isHidden = false
            // 2) la ventana se contrae hacia la esquina y el logo se recoloca
            self.programmaticMove = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(target, display: true)
                self.panel.animator().alphaValue = 0.72
                self.logo.animator().frame = NSRect(x: 6, y: 6, width: self.compactSize - 12, height: self.compactSize - 12)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.programmaticMove = false
                if self.isCompact { self.logo.frame = NSRect(x: 6, y: 6, width: self.compactSize - 12, height: self.compactSize - 12) }
            })
        })
    }

    func expand() {
        guard isCompact else { return }
        isCompact = false
        let f = panel.frame
        let target = NSRect(x: f.maxX - fullSize.width, y: f.minY, width: fullSize.width, height: fullSize.height)
        tapButton.isHidden = true
        effectView.layer?.cornerRadius = 30
        effectView.maskImage = roundedMask(radius: 30)
        title.alphaValue = 0; scroll.alphaValue = 0; stopButton.alphaValue = 0
        title.isHidden = false; scroll.isHidden = false; stopButton.isHidden = false; muteButton.isHidden = false
        programmaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            logo.animator().frame = NSRect(x: 22, y: (fullSize.height - 92) / 2, width: 92, height: 92)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.programmaticMove = false
            guard !self.isCompact else { return }
            self.logo.frame = NSRect(x: 22, y: (self.fullSize.height - 92) / 2, width: 92, height: 92)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                self.title.animator().alphaValue = 1
                self.scroll.animator().alphaValue = 1
                self.stopButton.animator().alphaValue = 1
            }
        })
    }

    @objc private func tapped() { onTap?() }

    private func savePosition() {
        guard !programmaticMove else { return }
        let f = panel.frame
        // Guardamos siempre la esquina inferior derecha, válida en ambos tamaños
        UserDefaults.standard.set([f.maxX, f.minY], forKey: "widgetCorner")
    }

    func set(_ t: String, _ b: String, _ mode: LogoView.Mode) {
        title.stringValue = t
        logo.mode = mode
        if mode != .speaking { lastSpoken = nil }
        if b != bodyText || mode != .speaking {
            bodyText = b
            render(spoken: mode == .speaking ? lastSpoken : nil, live: mode == .listening)
        }
    }

    /// Cambia solo el título (estado) sin tocar el texto.
    func setTitle(_ t: String) { title.stringValue = t }

    /// Resalta la palabra que Claude está pronunciando y desplaza el texto hasta ella.
    func highlight(_ range: NSRange) {
        lastSpoken = range
        render(spoken: range, live: false)
    }

    private func render(spoken: NSRange?, live: Bool) {
        let ns = bodyText as NSString
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: fg.withAlphaComponent(live ? 0.9 : 0.78),
            .paragraphStyle: para,
        ]
        let attr = NSMutableAttributedString(string: bodyText, attributes: base)
        var focusRange: NSRange? = nil
        if let spoken, spoken.location != NSNotFound, NSMaxRange(spoken) <= ns.length {
            // Ya dicho: normal. Palabra actual: brillante. Por decir: atenuado.
            attr.addAttribute(.foregroundColor, value: fg.withAlphaComponent(0.45), range: NSRange(location: NSMaxRange(spoken), length: ns.length - NSMaxRange(spoken)))
            attr.addAttributes([.foregroundColor: fg, .font: NSFont.systemFont(ofSize: 15, weight: .semibold)], range: spoken)
            focusRange = spoken
        } else if live, ns.length > 0 {
            // Última palabra dicha más brillante, como si fuera apareciendo
            let lastSpace = ns.range(of: " ", options: .backwards)
            let start = lastSpace.location == NSNotFound ? 0 : lastSpace.location + 1
            let r = NSRange(location: start, length: ns.length - start)
            attr.addAttributes([.foregroundColor: fg, .font: NSFont.systemFont(ofSize: 15, weight: .medium)], range: r)
            focusRange = r
        }
        body.textStorage?.setAttributedString(attr)
        scrollToFocus(focusRange)
    }

    private func scrollToFocus(_ range: NSRange?) {
        guard let lm = body.layoutManager, let tc = body.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let visibleH = scroll.contentSize.height
        var targetY: CGFloat
        if let range, range.location != NSNotFound {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            // Mantén la palabra enfocada en la parte baja del área visible
            targetY = rect.maxY + body.textContainerInset.height - visibleH + 6
        } else {
            targetY = used.height + body.textContainerInset.height * 2 - visibleH
        }
        targetY = max(0, min(targetY, max(0, used.height + body.textContainerInset.height * 2 - visibleH)))
        let clip = scroll.contentView
        if abs(clip.bounds.origin.y - targetY) < 1 { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        }
        scroll.reflectScrolledClipView(clip)
    }
}

// MARK: - Panel para escribir una orden

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class InputPanel: NSObject, NSTextFieldDelegate {
    private let panel: KeyPanel
    private let field = NSTextField(frame: .zero)
    var onSubmit: ((String) -> Void)?

    override init() {
        let w: CGFloat = 560, h: CGFloat = 60
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.maskImage = roundedMask(radius: 16)
        panel.contentView = effect
        field.frame = NSRect(x: 18, y: 14, width: w - 36, height: 32)
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Escríbele a Claude…  (Enter envía, Esc cancela)"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        effect.addSubview(field)
        super.init()
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
    }

    func open() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY + 120))
        }
        field.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        field.becomeFirstResponder()
    }
    func close() { panel.orderOut(nil) }

    @objc private func submit() {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        if !t.isEmpty { onSubmit?(t) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
}

// MARK: - Ventana de ajustes

final class SettingsWindow: NSObject {
    private var window: NSWindow?
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let voiceENPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rateSlider = NSSlider(value: 0.52, minValue: 0.40, maxValue: 0.66, target: nil, action: nil)
    private let neuralCheck = NSButton(checkboxWithTitle: "Voz neuronal local (Kokoro): más natural, todo en tu Mac", target: nil, action: nil)
    private let neuralESPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let neuralENPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let neuralStatus = NSTextField(labelWithString: "")
    private let neuralInstall = NSButton(title: "Instalar Kokoro…", target: nil, action: nil)
    private let rateLabel = NSTextField(labelWithString: "")
    private let waitStepper = NSStepper(frame: .zero)
    private let waitLabel = NSTextField(labelWithString: "")
    private let themeCheck = NSButton(checkboxWithTitle: "Tema claro", target: nil, action: nil)
    private let indicatorCheck = NSButton(checkboxWithTitle: "Indicador pequeño en reposo", target: nil, action: nil)
    private let soundCheck = NSButton(checkboxWithTitle: "Sonido al enviar una orden", target: nil, action: nil)
    private let taskEffortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let listenKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let typeKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopups: [String: NSPopUpButton] = ["simple": NSPopUpButton(), "normal": NSPopUpButton(), "profundo": NSPopUpButton()]
    weak var controller: Controller?

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // Etiquetas de la pestaña Uso, por clave "fila.columna"
    private var usageLabels: [String: NSTextField] = [:]
    private let usageModels = NSGridView(numberOfColumns: 2, rows: 0)
    private let usageKinds = NSGridView(numberOfColumns: 2, rows: 0)
    private let usageAlertField = NSTextField(string: "")
    private let memoryList = NSStackView()
    private let routinesList = NSStackView()
    private let memoryField = NSTextField(string: "")
    private var tabView: NSTabView?

    private func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        return l
    }
    private func note(_ t: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: t)
        n.font = .systemFont(ofSize: 11); n.textColor = .secondaryLabelColor
        n.preferredMaxLayoutWidth = 470
        return n
    }
    private func inline(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views); r.spacing = spacing; r.alignment = .centerY
        return r
    }

    /// Bloque de una pestaña: los títulos de sección y las notas (filas de un solo view) van alineados al borde
    /// izquierdo; las filas etiqueta + control se agrupan en rejillas de dos columnas (etiqueta a la derecha en una
    /// columna de ancho fijo, control a la izquierda), así todas las rejillas de la pestaña quedan alineadas entre sí.
    private func grid(_ rows: [[NSView]]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        var pending: [[NSView]] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let g = NSGridView(views: pending)
            g.rowSpacing = 9; g.columnSpacing = 12
            g.rowAlignment = .firstBaseline
            g.column(at: 0).xPlacement = .trailing
            g.column(at: 0).width = 190
            g.column(at: 1).xPlacement = .leading
            stack.addArrangedSubview(g)
            pending = []
        }
        for r in rows {
            if r.count == 1 {
                flush()
                let v = r[0]
                let isHeader = (v as? NSTextField)?.font?.fontDescriptor.symbolicTraits.contains(.bold) == true
                if isHeader, let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
                stack.addArrangedSubview(v)
                if let f = v as? NSTextField { f.alignment = .left }
            } else {
                pending.append(r)
            }
        }
        flush()
        return stack
    }
    private func section(_ t: String) -> NSTextField {
        let h = NSTextField(labelWithString: t)
        h.font = .boldSystemFont(ofSize: 13)
        return h
    }

    /// Pestaña con la rejilla centrada y con márgenes.
    private func tab(_ title: String, _ content: NSView) -> NSTabViewItem {
        let v = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            content.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
        ])
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = v
        return item
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Ajustes de Claude Voice"
        w.isReleasedWhenClosed = false
        window = w

        // Voz
        voicePopup.target = self; voicePopup.action = #selector(voiceChanged)
        voiceENPopup.target = self; voiceENPopup.action = #selector(voiceENChanged)
        rateSlider.target = self; rateSlider.action = #selector(rateChanged)
        rateSlider.isContinuous = false
        rateSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        rateLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let test = NSButton(title: "Escuchar muestra", target: self, action: #selector(testVoice))
        let more = NSButton(title: "Descargar más voces…", target: self, action: #selector(openVoiceSettings))
        neuralCheck.target = self; neuralCheck.action = #selector(neuralChanged)
        neuralESPopup.addItems(withTitles: NeuralVoice.voicesES.map { $0.1 }); neuralESPopup.target = self; neuralESPopup.action = #selector(neuralVoiceChanged(_:))
        neuralENPopup.addItems(withTitles: NeuralVoice.voicesEN.map { $0.1 }); neuralENPopup.target = self; neuralENPopup.action = #selector(neuralVoiceChanged(_:))
        neuralInstall.target = self; neuralInstall.action = #selector(installNeural)
        neuralStatus.font = .systemFont(ofSize: 11); neuralStatus.textColor = .secondaryLabelColor
        for p in [voicePopup, voiceENPopup, neuralESPopup, neuralENPopup] { p.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let voiceGrid = grid([
            [section("Voces de Apple")],
            [label("En español:"), voicePopup],
            [label("En inglés:"), voiceENPopup],
            [label("Velocidad de lectura:"), inline([rateSlider, rateLabel])],
            [NSGridCell.emptyContentView, inline([test, more])],
            [note("Las voces Mejorada y Premium se descargan gratis desde Ajustes del Sistema → Accesibilidad → Contenido hablado → Voz del sistema → Gestionar voces. Aparecen aquí al reabrir este panel.")],
            [section("Voz neuronal (Kokoro, en tu Mac)")],
            [NSGridCell.emptyContentView, neuralCheck],
            [label("En español:"), neuralESPopup],
            [label("En inglés:"), neuralENPopup],
            [NSGridCell.emptyContentView, inline([neuralInstall, neuralStatus])],
            [note("Kokoro-82M (licencia Apache 2.0) corre en tu Mac y nada sale de ella. La instalación descarga PyTorch y el modelo (~1 GB) una sola vez. Si el servidor no responde, se usa la voz de Apple.")],
        ])

        // Conversación
        waitStepper.minValue = 3; waitStepper.maxValue = 20; waitStepper.increment = 1
        waitStepper.target = self; waitStepper.action = #selector(waitChanged)
        soundCheck.target = self; soundCheck.action = #selector(soundChanged)
        taskEffortPopup.addItems(withTitles: ["Rápida (razona poco)", "Equilibrada", "Cuidadosa (razona mucho)"])
        taskEffortPopup.target = self; taskEffortPopup.action = #selector(taskEffortChanged)
        for (k, p) in modelPopups {
            p.addItems(withTitles: ["Haiku (rápido y ligero)", "Sonnet (equilibrado)", "Opus (potente)", "Fable (el más potente)"])
            p.target = self; p.action = #selector(modelChanged(_:))
            p.identifier = NSUserInterfaceItemIdentifier(k)
        }
        for p in [taskEffortPopup, modelPopups["simple"]!, modelPopups["normal"]!, modelPopups["profundo"]!] { p.widthAnchor.constraint(equalToConstant: 240).isActive = true }
        let convGrid = grid([
            [section("Escucha")],
            [label("Espera tras responder:"), inline([waitStepper, waitLabel])],
            [NSGridCell.emptyContentView, soundCheck],
            [section("Modelos")],
            [label("Órdenes simples:"), modelPopups["simple"]!],
            [label("Órdenes normales:"), modelPopups["normal"]!],
            [label("Cuando pides pensar a fondo:"), modelPopups["profundo"]!],
            [label("Velocidad de tareas largas:"), taskEffortPopup],
            [note("Las órdenes simples (hora, abrir apps, preguntas cortas) usan el modelo ligero; \"piensa bien\" o \"a fondo\" en la orden sube al modelo grande.")],
        ])

        // Widget y atajos
        themeCheck.target = self; themeCheck.action = #selector(themeChanged)
        indicatorCheck.target = self; indicatorCheck.action = #selector(indicatorChanged)
        for p in [listenKeyPopup, typeKeyPopup] {
            p.addItems(withTitles: Controller.hotkeyPresets.map { $0.0 })
            p.target = self; p.action = #selector(hotkeyChanged(_:))
            p.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        let widgetGrid = grid([
            [section("Widget")],
            [NSGridCell.emptyContentView, themeCheck],
            [NSGridCell.emptyContentView, indicatorCheck],
            [section("Atajos de teclado")],
            [label("Escuchar ahora:"), listenKeyPopup],
            [label("Escribir una orden:"), typeKeyPopup],
            [note("Esc dos veces seguidas cancela la orden en curso. El botón 🔊 del widget silencia la voz sin dejar de escribir.")],
        ])

        // Uso
        let usageGrid = NSGridView(numberOfColumns: 6, rows: 0)
        usageGrid.rowSpacing = 6; usageGrid.columnSpacing = 18
        let heads = ["", "Órdenes", "Entrada", "Salida", "Caché", "Costo"]
        usageGrid.addRow(with: heads.map { h -> NSView in let l = NSTextField(labelWithString: h); l.font = .systemFont(ofSize: 11, weight: .semibold); l.textColor = .secondaryLabelColor; return l })
        for r in ["Hoy", "Este mes", "Total"] {
            var views: [NSView] = [{ let l = NSTextField(labelWithString: r); l.font = .systemFont(ofSize: 13, weight: .medium); return l }()]
            for c in ["turns", "input", "output", "cache", "cost"] {
                let l = NSTextField(labelWithString: "–"); l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                usageLabels["\(r).\(c)"] = l; views.append(l)
            }
            usageGrid.addRow(with: views)
        }
        for c in 1..<6 { usageGrid.column(at: c).xPlacement = .trailing }
        usageModels.rowSpacing = 4; usageModels.columnSpacing = 18
        usageKinds.rowSpacing = 4; usageKinds.columnSpacing = 18
        usageAlertField.placeholderString = "0 = sin aviso"
        usageAlertField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        usageAlertField.target = self; usageAlertField.action = #selector(usageAlertChanged)
        let alertRow = inline([label("Avisar si el mes pasa de:"), usageAlertField, { let l = NSTextField(labelWithString: "USD"); return l }()])
        let openUsage = NSButton(title: "Abrir uso.json", target: self, action: #selector(openUsageFile))
        let resetUsage = NSButton(title: "Reiniciar contadores…", target: self, action: #selector(resetUsage))
        let usageStack = NSStackView(views: [
            section("Tokens y costo del widget"),
            usageGrid,
            section("Por modelo, este mes"),
            usageModels,
            section("Por tipo, este mes"),
            usageKinds,
            alertRow,
            inline([openUsage, resetUsage]),
            note("Cuenta cada orden, tarea y plan que pasa por Claude Code, incluidas las tareas en segundo plano. \"Caché\" es la parte del contexto reutilizada entre turnos (mucho más barata). El costo es el precio de lista de la API que reporta Claude Code; con una suscripción Pro o Max no se cobra aparte, sirve de referencia."),
        ])
        usageStack.orientation = .vertical; usageStack.alignment = .leading; usageStack.spacing = 12

        let tv = NSTabView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        tv.addTabViewItem(tab("Voz", voiceGrid))
        tv.addTabViewItem(tab("Conversación", convGrid))
        tv.addTabViewItem(tab("Widget y atajos", widgetGrid))
        memoryList.orientation = .vertical; memoryList.alignment = .leading; memoryList.spacing = 4
        routinesList.orientation = .vertical; routinesList.alignment = .leading; routinesList.spacing = 4
        memoryField.placeholderString = "Algo que deba recordar de ti…"
        memoryField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let addMemory = NSButton(title: "Guardar", target: self, action: #selector(addMemoryPressed))
        let openCtx = NSButton(title: "Abrir contexto.md", target: self, action: #selector(openContextFile))
        let memoryStack = NSStackView(views: [
            section("Lo que sé de ti"),
            note("Cada línea viene de un \"recuerda que…\" tuyo o de algo que Claude anotó por su cuenta. Se incluye en cada orden para que las respuestas tengan contexto. Borra lo que no sea cierto."),
            memoryList,
            inline([memoryField, addMemory, openCtx]),
            section("Rutinas"),
            note("Órdenes que se ejecutan solas por voz cuando el asistente está libre. Se crean hablando: \"cada mañana a las 8 dime el clima y mi agenda\", \"todos los lunes a las 9 revisa mi correo\"."),
            routinesList,
        ])
        memoryStack.orientation = .vertical; memoryStack.alignment = .leading; memoryStack.spacing = 10
        tv.addTabViewItem(tab("Memoria y rutinas", memoryStack))
        tv.addTabViewItem(tab("Uso", usageStack))
        tv.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))
        content.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tv.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tv.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            tv.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        w.contentView = content
        tabView = tv
    }

    private func refreshUsage() {
        let u = UsageStore.shared
        let rows: [(String, UsageStore.Bucket)] = [("Hoy", u.today), ("Este mes", u.month.0), ("Total", u.total.0)]
        for (r, b) in rows {
            usageLabels["\(r).turns"]?.stringValue = "\(b.turns)"
            usageLabels["\(r).input"]?.stringValue = UsageStore.tokens(b.input)
            usageLabels["\(r).output"]?.stringValue = UsageStore.tokens(b.output)
            usageLabels["\(r).cache"]?.stringValue = UsageStore.tokens(b.cacheRead + b.cacheWrite)
            usageLabels["\(r).cost"]?.stringValue = UsageStore.money(b.cost)
        }
        // removeRow no saca las vistas de la jerarquía: hay que quitarlas antes o se apilan unas sobre otras
        for g in [usageModels, usageKinds] {
            while g.numberOfRows > 0 {
                let r = g.row(at: 0)
                for c in 0..<g.numberOfColumns { r.cell(at: c).contentView?.removeFromSuperview() }
                g.removeRow(at: 0)
            }
        }
        let kinds = u.monthKinds.sorted { $0.value.cost > $1.value.cost }
        for (k, b) in kinds {
            let name = NSTextField(labelWithString: k); name.font = .systemFont(ofSize: 12, weight: .medium)
            let detail = NSTextField(labelWithString: "\(b.turns) turnos · \(UsageStore.tokens(b.tokens)) tokens · \(UsageStore.money(b.cost))")
            detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.textColor = .secondaryLabelColor
            usageKinds.addRow(with: [name, detail])
        }
        do {
            let name = NSTextField(labelWithString: "Rutas locales"); name.font = .systemFont(ofSize: 12, weight: .medium)
            let total = u.month.0.turns + u.monthLocal
            let pct = total > 0 ? Int(Double(u.monthLocal) * 100 / Double(total)) : 0
            let detail = NSTextField(labelWithString: "\(u.monthLocal) órdenes sin modelo (hora, volumen, recordatorios…) · \(pct)% del total · $0")
            detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.textColor = .secondaryLabelColor
            usageKinds.addRow(with: [name, detail])
        }
        usageAlertField.stringValue = UsageStore.alertUSD > 0 ? String(format: "%.0f", UsageStore.alertUSD) : ""
        let models = u.month.1.sorted { $0.value.cost > $1.value.cost }
        if models.isEmpty {
            usageModels.addRow(with: [note("Todavía no hay uso este mes.")])
        } else {
            for (m, b) in models {
                let name = NSTextField(labelWithString: m); name.font = .systemFont(ofSize: 12, weight: .medium)
                let detail = NSTextField(labelWithString: "\(b.turns) órdenes · \(UsageStore.tokens(b.tokens)) tokens · \(UsageStore.money(b.cost))")
                detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); detail.textColor = .secondaryLabelColor
                usageModels.addRow(with: [name, detail])
            }
        }
    }

    @objc private func usageAlertChanged() {
        UserDefaults.standard.set(Double(usageAlertField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0, forKey: "usageAlertUSD")
    }
    @objc private func openUsageFile() {
        if !FileManager.default.fileExists(atPath: UsageStore.file.path) { try? "{}".write(to: UsageStore.file, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(UsageStore.file)
    }
    @objc private func resetUsage() {
        let a = NSAlert()
        a.messageText = "¿Reiniciar los contadores de uso?"
        a.informativeText = "Se borran los tokens y el costo acumulados en uso.json. No afecta a tu cuenta."
        a.addButton(withTitle: "Reiniciar"); a.addButton(withTitle: "Cancelar")
        if a.runModal() == .alertFirstButtonReturn { UsageStore.shared.reset(); refreshUsage() }
    }

    func refresh() {
        guard let c = controller else { return }
        voicePopup.removeAllItems()
        let current = c.speaker.voice?.identifier
        var lastLang = ""
        for v in Speaker.selectableVoices() {
            if v.language != lastLang {
                if !lastLang.isEmpty { voicePopup.menu?.addItem(.separator()) }
                lastLang = v.language
            }
            let i = NSMenuItem(title: Speaker.label(for: v), action: nil, keyEquivalent: "")
            i.representedObject = v.identifier
            voicePopup.menu?.addItem(i)
            if v.identifier == current { voicePopup.select(i) }
        }
        voiceENPopup.removeAllItems()
        let currentEN = c.speaker.voiceEN?.identifier
        var lastEN = ""
        for v in Speaker.englishVoices() {
            if v.language != lastEN {
                if !lastEN.isEmpty { voiceENPopup.menu?.addItem(.separator()) }
                lastEN = v.language
            }
            let i = NSMenuItem(title: Speaker.label(for: v), action: nil, keyEquivalent: "")
            i.representedObject = v.identifier
            voiceENPopup.menu?.addItem(i)
            if v.identifier == currentEN { voiceENPopup.select(i) }
        }
        rateSlider.doubleValue = Double(c.speaker.rate)
        rateLabel.stringValue = rateText(Double(c.speaker.rate))
        waitStepper.doubleValue = Double(c.followUpSeconds)
        waitLabel.stringValue = "\(c.followUpSeconds) segundos"
        taskEffortPopup.selectItem(at: ["low": 0, "medium": 1, "high": 2][c.taskEffort] ?? 1)
        listenKeyPopup.selectItem(at: Controller.listenHotkey)
        typeKeyPopup.selectItem(at: Controller.typeHotkey)
        themeCheck.state = c.overlay.isLight ? .on : .off
        indicatorCheck.state = c.overlay.showsIndicator ? .on : .off
        soundCheck.state = c.sendSound ? .on : .off

        let tiers = loadModelTiers()
        let idx = ["haiku": 0, "sonnet": 1, "opus": 2, "default": 3]
        for (k, p) in modelPopups { p.selectItem(at: idx[tiers[k] ?? "default"] ?? 3) }
        refreshNeural()
        refreshUsage()
        refreshMemory()
    }

    private func refreshMemory() {
        for v in memoryList.arrangedSubviews + routinesList.arrangedSubviews { v.removeFromSuperview() }
        let lines = MemoryFile.lines()
        var any = false
        for (i, l) in lines.enumerated() where l.hasPrefix("- ") {
            any = true
            let text = NSTextField(wrappingLabelWithString: MemoryFile.strip(l))
            text.preferredMaxLayoutWidth = 420; text.font = .systemFont(ofSize: 12)
            let when = NSTextField(labelWithString: MemoryFile.date(of: l).map { d -> String in
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; let o = DateFormatter(); o.dateFormat = "d MMM"; o.locale = Locale(identifier: "es")
                let fresh = f.date(from: d).map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
                return (fresh ? "nuevo · " : "") + (f.date(from: d).map { o.string(from: $0) } ?? d)
            } ?? "")
            when.font = .systemFont(ofSize: 10); when.textColor = .secondaryLabelColor
            when.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let del = NSButton(title: "Borrar", target: self, action: #selector(deleteMemory(_:)))
            del.controlSize = .small; del.tag = i
            let row = inline([del, when, text]); row.alignment = .firstBaseline
            memoryList.addArrangedSubview(row)
        }
        if !any { memoryList.addArrangedSubview(note("Todavía no hay nada guardado.")) }
        guard let c = controller else { return }
        if c.routines.items.isEmpty { routinesList.addArrangedSubview(note("No hay rutinas.")) }
        for r in c.routines.items {
            let text = NSTextField(labelWithString: "\(r.whenText.prefix(1).capitalized + r.whenText.dropFirst()): \(r.text)")
            text.font = .systemFont(ofSize: 12)
            let del = NSButton(title: "Borrar", target: self, action: #selector(deleteRoutine(_:)))
            del.controlSize = .small; del.identifier = NSUserInterfaceItemIdentifier(r.id)
            routinesList.addArrangedSubview(inline([del, text]))
        }
    }
    @objc private func deleteMemory(_ sender: NSButton) { MemoryFile.remove(lineIndex: sender.tag); refreshMemory() }
    @objc private func deleteRoutine(_ sender: NSButton) { if let id = sender.identifier?.rawValue { controller?.routines.remove(id: id) }; refreshMemory() }
    @objc private func addMemoryPressed() {
        let t = memoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        MemoryFile.append(t); memoryField.stringValue = ""; refreshMemory()
    }
    @objc private func openContextFile() { NSWorkspace.shared.open(contextFile) }

    private func refreshNeural() {
        neuralCheck.state = NeuralVoice.enabled ? .on : .off
        neuralCheck.isEnabled = NeuralVoice.installed
        neuralESPopup.selectItem(at: NeuralVoice.voicesES.firstIndex { $0.0 == NeuralVoice.voiceES } ?? 0)
        neuralENPopup.selectItem(at: NeuralVoice.voicesEN.firstIndex { $0.0 == NeuralVoice.voiceEN } ?? 0)
        neuralInstall.title = NeuralVoice.installed ? "Reinstalar Kokoro…" : "Instalar Kokoro…"
        neuralStatus.stringValue = "Estado: " + (controller?.speaker.neural.statusText ?? "")
    }

    @objc private func neuralChanged() {
        NeuralVoice.enabled = neuralCheck.state == .on
        if NeuralVoice.enabled { controller?.speaker.neural.start() } else { controller?.speaker.neural.stop() }
        refreshNeural()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshNeural() }
    }
    @objc private func neuralVoiceChanged(_ sender: NSPopUpButton) {
        if sender === neuralESPopup {
            UserDefaults.standard.set(NeuralVoice.voicesES[max(0, sender.indexOfSelectedItem)].0, forKey: "neuralVoiceES")
            controller?.testVoice()
        } else {
            UserDefaults.standard.set(NeuralVoice.voicesEN[max(0, sender.indexOfSelectedItem)].0, forKey: "neuralVoiceEN")
            controller?.testVoice(english: true)
        }
    }
    @objc private func installNeural() {
        // El instalador se copia a ~/claude-voice/tts con install.sh; corre en Terminal para que veas el progreso
        guard FileManager.default.fileExists(atPath: NeuralVoice.setupScript.path) else {
            neuralStatus.stringValue = "Falta \(NeuralVoice.setupScript.path): ejecuta install.sh del repo"
            return
        }
        NSWorkspace.shared.open([NeuralVoice.setupScript], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
        neuralStatus.stringValue = "Instalando en Terminal… al terminar, activa la casilla"
    }

    private func rateText(_ r: Double) -> String {
        r < 0.47 ? "Lenta" : r < 0.55 ? "Normal" : r < 0.61 ? "Rápida" : "Muy rápida"
    }

    @objc private func voiceChanged() {
        guard let id = voicePopup.selectedItem?.representedObject as? String else { return }
        controller?.speaker.setVoice(identifier: id)
        controller?.testVoice()
    }
    @objc private func voiceENChanged() {
        guard let id = voiceENPopup.selectedItem?.representedObject as? String else { return }
        controller?.speaker.setEnglishVoice(identifier: id)
        controller?.testVoice(english: true)
    }
    @objc private func rateChanged() {
        controller?.speaker.setRate(Float(rateSlider.doubleValue))
        rateLabel.stringValue = rateText(rateSlider.doubleValue)
        controller?.testVoice()
    }
    @objc private func testVoice() { controller?.testVoice() }
    @objc private func openVoiceSettings() { controller?.openVoiceSettings() }
    @objc private func waitChanged() {
        let v = Int(waitStepper.doubleValue)
        UserDefaults.standard.set(v, forKey: "followUpSeconds")
        waitLabel.stringValue = "\(v) segundos"
    }
    @objc private func themeChanged() {
        UserDefaults.standard.set(themeCheck.state == .on, forKey: "lightTheme")
        controller?.overlay.applyTheme()
    }
    @objc private func indicatorChanged() {
        UserDefaults.standard.set(indicatorCheck.state == .on, forKey: "idleIndicator")
        controller?.refreshIdleIndicator()
    }
    @objc private func soundChanged() {
        UserDefaults.standard.set(soundCheck.state == .on, forKey: "sendSound")
    }
    @objc private func taskEffortChanged() {
        UserDefaults.standard.set(["low", "medium", "high"][max(0, taskEffortPopup.indexOfSelectedItem)], forKey: "taskEffort")
    }
    @objc private func hotkeyChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(listenKeyPopup.indexOfSelectedItem, forKey: "hotkeyListen")
        UserDefaults.standard.set(typeKeyPopup.indexOfSelectedItem, forKey: "hotkeyType")
        controller?.reregisterHotkeys()
    }
    @objc private func modelChanged(_ sender: NSPopUpButton) {
        var tiers = loadModelTiers()
        let alias = ["haiku", "sonnet", "opus", "default"][max(0, sender.indexOfSelectedItem)]
        if let k = sender.identifier?.rawValue { tiers[k] = alias }
        saveModelTiers(tiers)
    }
}

// MARK: - Historial de conversaciones

struct Conversation {
    var date: String
    var sessionId: String?
    var lines: [String]
    var title: String { lines.first { $0.hasPrefix("> ") }.map { String($0.dropFirst(2)) } ?? "(sin órdenes)" }
    var text: String { lines.joined(separator: "\n") }
}

func loadConversations() -> [Conversation] {
    guard let t = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
    var convs: [Conversation] = []
    var cur = Conversation(date: "", sessionId: nil, lines: [])
    func flush() { if !cur.lines.isEmpty { convs.append(cur) }; cur = Conversation(date: "", sessionId: nil, lines: []) }
    for raw in t.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(raw)
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
        let ts = String(line[line.index(after: line.startIndex)..<close])
        let body = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("--- sesión ") {
            flush()
            cur.sessionId = body.replacingOccurrences(of: "--- sesión ", with: "").replacingOccurrences(of: " ---", with: "")
            cur.date = ts
            continue
        }
        if body.hasPrefix("---") { flush(); continue }
        if cur.date.isEmpty { cur.date = ts }
        cur.lines.append(body.replacingOccurrences(of: #"^> \[[^\]]+\] "#, with: "> ", options: String.CompareOptions.regularExpression))
    }
    flush()
    return convs.reversed()
}

final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private let table = NSTableView()
    private let text = NSTextView()
    private let search = NSSearchField()
    private let resumeButton = NSButton(title: "Retomar esta conversación", target: nil, action: nil)
    private var all: [Conversation] = []
    private var shown: [Conversation] = []
    weak var controller: Controller?

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Historial de Claude Voice"
        w.isReleasedWhenClosed = false
        window = w
        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        search.frame = NSRect(x: 12, y: content.bounds.height - 40, width: 280, height: 26)
        search.autoresizingMask = [.minYMargin]
        search.placeholderString = "Buscar…"
        search.delegate = self
        content.addSubview(search)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.title = "Conversaciones"
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 44
        let left = NSScrollView(frame: NSRect(x: 12, y: 48, width: 280, height: content.bounds.height - 100))
        left.autoresizingMask = [.height]
        left.documentView = table
        left.hasVerticalScroller = true
        left.borderType = .bezelBorder
        content.addSubview(left)

        let right = NSScrollView(frame: NSRect(x: 304, y: 48, width: content.bounds.width - 316, height: content.bounds.height - 100))
        right.autoresizingMask = [.width, .height]
        text.isEditable = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        right.documentView = text
        right.hasVerticalScroller = true
        right.borderType = .bezelBorder
        content.addSubview(right)

        resumeButton.frame = NSRect(x: 304, y: 12, width: 220, height: 28)
        resumeButton.target = self
        resumeButton.action = #selector(resumeSelected)
        resumeButton.isEnabled = false
        content.addSubview(resumeButton)
        w.contentView = content
    }

    private func reload() {
        all = loadConversations()
        applyFilter()
    }

    private func applyFilter() {
        let q = normalize(search.stringValue)
        shown = q.isEmpty ? all : all.filter { normalize($0.text).contains(q) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { text.string = ""; resumeButton.isEnabled = false }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = shown[row]
        let cell = NSTextField(wrappingLabelWithString: "\(c.date)\n\(c.title)")
        cell.font = .systemFont(ofSize: 12)
        cell.maximumNumberOfLines = 2
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let c = shown[row]
        text.string = c.text
        resumeButton.isEnabled = c.sessionId != nil
    }
    @objc private func resumeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count, let sid = shown[row].sessionId else { return }
        controller?.resumeSession(sid)
        window?.orderOut(nil)
    }
}

// MARK: - Reconocimiento de voz continuo

final class Listener {
    private let engine = AVAudioEngine()
    // Un solo reconocedor (es-US entiende también inglés). Dos a la vez no conviven en macOS.
    private let recognizers: [(String, SFSpeechRecognizer?)] = [("es", SFSpeechRecognizer(locale: Locale(identifier: "es-US")))]
    private var taskStart: [String: Date] = [:]
    private var restartPending = false
    private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [String: SFSpeechRecognitionTask] = [:]
    private var recognizer: SFSpeechRecognizer? { recognizers.first?.1 }
    private let lock = NSLock()
    private var generation = 0
    var vocab: [String] = []
    var onText: ((String, String) -> Void)?   // (texto, idioma "es"/"en")
    var onLevel: ((CGFloat) -> Void)?
    /// Se llama cuando el reconocedor terminó una transcripción por su cuenta (pausa larga o límite) y empieza otra.
    var onAutoRestart: (() -> Void)?
    var beforeStart: ((AVAudioEngine) -> Void)?
    private(set) var lastRestart = Date()
    private var peak: Float = 0
    private var lastPeakLog = Date()

    private var playerAttached = false
    private var configObserver: Any?
    var engineRunning: Bool { engine.isRunning }

    /// Con la cancelación de eco activa el micrófono pierde sensibilidad; la dejamos puesta solo mientras Claude habla.
    /// Con auriculares la voz de Claude no llega al micrófono: no hace falta cancelación de eco (que resta
    /// sensibilidad) y se puede interrumpir hablando normal. Se recalcula al cambiar el dispositivo de salida.
    private(set) var outputIsHeadphones = false
    private var outputName = ""
    func refreshOutputDevice() {
        let (isPhones, name) = Listener.currentOutput()
        if isPhones != outputIsHeadphones || name != outputName {
            outputIsHeadphones = isPhones; outputName = name
            logApp("Salida de audio: \(name)\(isPhones ? " (auriculares: sin cancelación de eco, interrupción sensible)" : "")")
        }
    }
    static func currentOutput() -> (Bool, String) {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return (false, "?") }
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioObjectPropertyName
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        let n = name as String
        let ln = n.lowercased()
        var transport = UInt32(0); size = 4
        addr.mSelector = kAudioDevicePropertyTransportType
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr {
            if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return (true, n) }
            if transport == kAudioDeviceTransportTypeUSB, ["head", "pods", "buds", "headset", "hyperx", "steelseries", "arctis", "logitech g"].contains(where: { ln.contains($0) }) { return (true, n) }
        }
        var source = UInt32(0); size = 4
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr, source == 0x6864_706E { return (true, n + " (audífonos)") }   // 'hdpn'
        return (ln.contains("headphone") || ln.contains("audifono") || ln.contains("auricular"), n)
    }

    func setEchoActive(_ active: Bool) {
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
        let want = active && !outputIsHeadphones
        if engine.inputNode.isVoiceProcessingBypassed != !want { engine.inputNode.isVoiceProcessingBypassed = !want }
    }

    /// Si cambia el dispositivo de audio (auriculares, AirPods), macOS detiene el motor: lo levantamos de nuevo.
    private func recoverEngine() {
        logApp("Cambió la configuración de audio; reinicio el motor")
        refreshOutputDevice()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        do { try startEngine(echo: useEchoCancellation) }
        catch {
            logApp("No pude reiniciar con cancelación de eco (\(error.localizedDescription)); reintento sin ella")
            engine.stop(); engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            try? startEngine(echo: false)
        }
        restart()
    }

    func startEngine() throws {
        refreshOutputDevice()
        do { try startEngine(echo: useEchoCancellation) }
        catch {
            logApp("Arranque con cancelación de eco falló (\(error.localizedDescription)); reintento sin ella")
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine.reset()
            try startEngine(echo: false)
        }
    }

    private func startEngine(echo: Bool) throws {
        let input = engine.inputNode
        if !playerAttached { beforeStart?(engine); playerAttached = true }
        _ = engine.mainMixerNode
        // Cancelación de eco de Apple: entrega muchos canales; usamos solo el canal 0.
        if input.isVoiceProcessingEnabled != echo { try input.setVoiceProcessingEnabled(echo) }
        var format = input.outputFormat(forBus: 0)
        if echo {
            // Atenuación inteligente: baja el resto del audio solo mientras alguien habla
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .default)
            }
            if format.sampleRate > 0 && format.channelCount > 0 { logApp(String(format: "Cancelación de eco activa (%d canales, %.0f Hz)", format.channelCount, format.sampleRate)) }
            else { try input.setVoiceProcessingEnabled(false); format = input.outputFormat(forBus: 0); logApp("Cancelación de eco no usable, desactivada") }
        } else {
            logApp("Micrófono en modo normal")
        }
        guard let mono48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono48, to: target) else {
            throw NSError(domain: "ClaudeVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pude crear el conversor de audio"])
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ClaudeVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: "No hay micrófono disponible"])
        }
        logApp(String(format: "Entrada: %.0f Hz x %d canales -> mono 16 kHz", format.sampleRate, format.channelCount))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, let src = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            // Canal 0 -> buffer mono
            guard let mono = AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: buf.frameLength) else { return }
            mono.frameLength = buf.frameLength
            let stride = Int(buf.stride)
            if let dst = mono.floatChannelData?[0] {
                var i = 0
                let n = Int(buf.frameLength)
                let gain: Float = micGain
                while i < n { dst[i] = gain == 1 ? src[i * stride] : tanhf(src[i * stride] * gain); i += 1 }
            }
            // Remuestreo a 16 kHz
            let ratio = target.sampleRate / mono48.sampleRate
            let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return mono
            }
            guard status != .error, out.frameLength > 0 else { return }
            self.lock.lock(); let reqs = Array(self.requests.values); self.lock.unlock()
            for r in reqs { r.append(out) }
            if let ch = out.floatChannelData?[0] {
                let n = Int(out.frameLength)
                var sum: Float = 0
                var i = 0
                while i < n { sum += ch[i] * ch[i]; i += 2 }
                let rms = sqrt(sum / Float(max(n / 2, 1)))
                self.peak = max(self.peak, rms)
                if debugText && Date().timeIntervalSince(self.lastPeakLog) > 5 {
                    logApp(String(format: "mic nivel máximo (5 s): %.4f", self.peak))
                    self.peak = 0; self.lastPeakLog = Date()
                }
                let lvl = CGFloat(min(1, rms * 10))
                DispatchQueue.main.async { self.onLevel?(lvl) }
            }
        }
        engine.prepare()
        try engine.start()
        setEchoActive(false)   // en reposo, micrófono limpio
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.recoverEngine() }
            }
        }
        logApp("Motor de audio iniciado. Reconocimiento local: \(recognizer?.supportsOnDeviceRecognition ?? false)")
    }

    /// Empieza una transcripción nueva (texto en blanco) en ambos idiomas.
    func restart() {
        restartPending = false
        lock.lock()
        generation += 1
        let gen = generation
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        requests.values.forEach { $0.endAudio() }; requests.removeAll()
        lock.unlock()
        lastRestart = Date()
        var anyAvailable = false
        for (lang, recognizer) in recognizers {
            guard let recognizer, recognizer.isAvailable else { continue }
            anyAvailable = true
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            req.contextualStrings = vocab
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            lock.lock(); requests[lang] = req; lock.unlock()
            let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                self.lock.lock(); let alive = (gen == self.generation); self.lock.unlock()
                guard alive else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if debugText { logApp("oí[\(lang)]: \(text)") }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.lock.lock(); let fresh = (gen == self.generation); self.lock.unlock()
                        if fresh { self.onText?(text, lang) }
                    }
                }
                if let error {
                    let ns = error as NSError
                    if !ns.localizedDescription.contains("canceled") { logApp("Reconocedor \(lang) error \(ns.domain) \(ns.code): \(ns.localizedDescription)") }
                }
                if error != nil || (result?.isFinal ?? false) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.lock.lock(); let still = (gen == self.generation); self.lock.unlock()
                        guard still, !self.restartPending else { return }
                        self.restartPending = true
                        let ranFor = Date().timeIntervalSince(self.taskStart[lang] ?? .distantPast)
                        let delay: TimeInterval = ranFor < 1.5 ? 1.5 : 0.05   // falló al instante: frena
                        if ranFor < 1.5 { logApp("Reconocedor \(lang) terminó a los \(String(format: "%.1f", ranFor)) s; reintento en 1.5 s") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self else { return }
                            self.restartPending = false
                            self.lock.lock(); let still2 = (gen == self.generation); self.lock.unlock()
                            if still2 { self.onAutoRestart?(); self.restart() }
                        }
                    }
                }
            }
            taskStart[lang] = Date()
            lock.lock(); tasks[lang] = task; lock.unlock()
        }
        if !anyAvailable {
            logApp("Reconocedor no disponible, reintento en 2 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.restart()
            }
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        requests.values.forEach { $0.endAudio() }; requests.removeAll()
        lock.unlock()
    }
}

// MARK: - Voz neuronal local (Kokoro)

/// Arranca el servidor de ~/claude-voice/tts (Kokoro-82M, todo en la Mac) y pide el audio frase por frase.
/// Si no está instalado, no responde o falla seguido, el Speaker usa la voz de Apple sin que se note.
final class NeuralVoice {
    static let dir = baseDir.appendingPathComponent("tts")
    static let python = dir.appendingPathComponent("venv/bin/python")
    static let script = dir.appendingPathComponent("kokoro_server.py")
    static let setupScript = dir.appendingPathComponent("setup_kokoro.sh")
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: script.path) }
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "neuralVoice") }
        set { UserDefaults.standard.set(newValue, forKey: "neuralVoice") }
    }
    static var voiceES: String { UserDefaults.standard.string(forKey: "neuralVoiceES") ?? "ef_dora" }
    static var voiceEN: String { UserDefaults.standard.string(forKey: "neuralVoiceEN") ?? "af_heart" }
    static let voicesES: [(String, String)] = [("ef_dora", "Dora (mujer)"), ("em_alex", "Alex (hombre)"), ("em_santa", "Santa (hombre)")]
    static let voicesEN: [(String, String)] = [("af_heart", "Heart (mujer)"), ("af_bella", "Bella (mujer)"), ("af_nicole", "Nicole (mujer)"),
                                               ("am_michael", "Michael (hombre)"), ("am_fenrir", "Fenrir (hombre)"), ("bf_emma", "Emma (británica)"), ("bm_george", "George (británico)")]
    private let port = 8765
    private var process: Process?
    private(set) var ready = false
    private var failures = 0
    private(set) var sessionDisabled = false   // tras fallos seguidos, voz de Apple hasta reiniciar
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    var statusText: String {
        if !NeuralVoice.installed { return "No instalada" }
        if !NeuralVoice.enabled { return "Desactivada" }
        if sessionDisabled { return "Falló; usando la voz de Apple" }
        return ready ? "Lista" : (process != nil ? "Arrancando…" : "Parada")
    }

    func start() {
        guard NeuralVoice.enabled, NeuralVoice.installed else { return }
        sessionDisabled = false; failures = 0
        guard process == nil else { return }
        let logURL = NeuralVoice.dir.appendingPathComponent("tts.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()
        let p = Process()
        p.executableURL = NeuralVoice.python
        p.arguments = [NeuralVoice.script.path, "--port", "\(port)"]
        p.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1", "VIRTUAL_ENV": NeuralVoice.dir.appendingPathComponent("venv").path]) { $1 }
        p.standardOutput = logHandle; p.standardError = logHandle
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil; self.ready = false
                logApp("El servidor de voz neuronal terminó (código \(proc.terminationStatus))")
            }
        }
        do {
            try p.run(); process = p
            logApp("Servidor de voz neuronal arrancando (pid \(p.processIdentifier))")
            pollHealth(attempt: 0)
        } catch { logApp("No pude arrancar la voz neuronal: \(error.localizedDescription)") }
    }

    private func pollHealth(attempt: Int) {
        guard process != nil, !ready, attempt < 120 else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        session.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if (resp as? HTTPURLResponse)?.statusCode == 200, data.map({ String(decoding: $0, as: UTF8.self) }) == "ok" {
                    self.ready = true
                    logApp("Voz neuronal lista")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollHealth(attempt: attempt + 1) }
                }
            }
        }.resume()
    }

    func stop() {
        guard let p = process else { return }
        process = nil; ready = false
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        logApp("Servidor de voz neuronal apagado")
    }

    /// Pide el audio de una frase. Devuelve en el hilo principal un buffer PCM (24 kHz mono) o nil si hay que usar Apple.
    func synthesize(_ text: String, lang: String, speed: Double, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        guard ready, !sessionDisabled else { completion(nil); return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tts")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 4 + Double(text.count) * 0.04
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "lang": lang, "voice": lang == "en" ? NeuralVoice.voiceEN : NeuralVoice.voiceES, "speed": speed])
        let t0 = Date()
        session.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { completion(nil); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, code == 200, data.count >= 4 else {
                    self.failures += 1
                    logApp("Voz neuronal falló (\(err?.localizedDescription ?? "estado \(code)"))")
                    if self.failures >= 3 { self.sessionDisabled = true; logApp("Voz neuronal desactivada hasta reiniciar; uso la voz de Apple") }
                    completion(nil); return
                }
                self.failures = 0
                let sr = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Sample-Rate") ?? "") ?? 24000
                guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false) else { completion(nil); return }
                let frames = AVAudioFrameCount(data.count / 4)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames), let dst = buf.floatChannelData?[0] else { completion(nil); return }
                buf.frameLength = frames
                data.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(dst, base, Int(frames) * 4) } }
                if debugText { logApp(String(format: "voz neuronal: %.1f s de audio en %.2f s", Double(frames) / sr, Date().timeIntervalSince(t0))) }
                completion(buf)
            }
        }.resume()
    }
}

// MARK: - Voz

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    let neural = NeuralVoice()
    private let synth = AVSpeechSynthesizer()
    private(set) var voice: AVSpeechSynthesisVoice?
    private(set) var voiceEN: AVSpeechSynthesisVoice? = Speaker.defaultEnglishVoice()
    var rate: Float = Float(UserDefaults.standard.object(forKey: "voiceRate") as? Double ?? 0.52)
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pending: [(String, Int)] = []
    private var writing = false
    private var queued = 0                       // locuciones encoladas o sonando
    private var generation = 0
    private var highlightTimer: Timer?
    private var highlightOwner: AnyObject? = nil
    var onFinish: (() -> Void)?
    var onRange: ((NSRange) -> Void)?
    var isSpeaking: Bool { queued > 0 }

    override init() {
        voice = Speaker.defaultVoice()
        super.init()
        synth.delegate = self
    }

    /// La voz guardada en ajustes o, si no hay, la de mejor calidad llamada Paulina.
    static func defaultVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "voiceIdentifier"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.name == voiceName }
        return candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: "es-MX")
    }

    static func defaultEnglishVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "voiceIdentifierEN"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let preferred = ["Samantha", "Ava", "Zoe", "Allison", "Evan", "Nathan", "Tom", "Alex", "Daniel", "Karen"]
        let best = en.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            let pa = preferred.firstIndex(of: a.name) ?? 99, pb = preferred.firstIndex(of: b.name) ?? 99
            return pa > pb
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func setEnglishVoice(identifier: String) {
        guard let v = AVSpeechSynthesisVoice(identifier: identifier) else { return }
        voiceEN = v
        UserDefaults.standard.set(identifier, forKey: "voiceIdentifierEN")
    }

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.sorted { a, b in
            if a.language != b.language { return a.language < b.language }
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }
    }

    func setVoice(identifier: String) {
        guard let v = AVSpeechSynthesisVoice(identifier: identifier) else { return }
        voice = v
        UserDefaults.standard.set(identifier, forKey: "voiceIdentifier")
    }

    func setRate(_ r: Float) {
        rate = r
        UserDefaults.standard.set(Double(r), forKey: "voiceRate")
    }

    /// Voces que vale la pena ofrecer: todas las mejoradas/premium de cualquier idioma y todas las de español.
    static func selectableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") }
            .sorted { a, b in
                let ae = a.language.hasPrefix("es"), be = b.language.hasPrefix("es")
                if ae != be { return ae }
                if a.language != b.language { return languageName(a.language) < languageName(b.language) }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func languageName(_ code: String) -> String {
        let loc = Locale(identifier: "es")
        return loc.localizedString(forIdentifier: code)?.capitalized ?? code
    }

    static func label(for v: AVSpeechSynthesisVoice) -> String {
        let q = v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Mejorada" : "Básica"
        return "\(v.name) · \(languageName(v.language)) · \(q)"
    }

    /// Debe llamarse antes de arrancar el motor.
    func attach(to engine: AVAudioEngine) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
    }

    func speak(_ text: String, offset: Int = 0) {
        guard let eng = player.engine, eng.isRunning else {
            logApp("No puedo hablar: el motor de audio no está corriendo")
            DispatchQueue.main.async { [weak self] in self?.onFinish?() }
            return
        }
        pending.append((text, offset))
        queued += 1
        if !player.isPlaying { player.play() }
        writeNext()
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        pending.removeAll()
        writing = false
        current = nil
        idleTimer?.invalidate(); idleTimer = nil
        finishTimers.forEach { $0.invalidate() }; finishTimers.removeAll()
        queued = 0
        player.stop()
        highlightTimer?.invalidate(); highlightTimer = nil
    }

    private func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let f = pcm.format
        if f.commonFormat == .pcmFormatFloat32 && f.sampleRate == outFormat.sampleRate && f.channelCount == 1 && !f.isInterleaved { return pcm }
        if converter == nil || converterInput != f {
            converter = AVAudioConverter(from: f, to: outFormat)
            converterInput = f
        }
        guard let conv = converter else { return nil }
        let ratio = outFormat.sampleRate / f.sampleRate
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        let st = conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return pcm
        }
        return st == .error ? nil : out
    }

    /// Estado de una locución: cada frase lleva su propio cronómetro para no mezclarse con la siguiente.
    private final class Utt {
        let text: String
        let offset: Int
        let gen: Int
        var frames: AVAudioFrameCount = 0
        var renderStart: Date? = nil
        var total: Double? = nil
        var written = false
        var finished = false
        var first = true
        var utterance: AVSpeechUtterance? = nil
        init(text: String, offset: Int, gen: Int) { self.text = text; self.offset = offset; self.gen = gen }
    }
    private var current: Utt? = nil
    private var idleTimer: Timer?

    private func writeNext() {
        guard !writing, let (text, offset) = pending.first else { return }
        pending.removeFirst()
        writing = true
        let utt = Utt(text: text, offset: offset, gen: generation)
        current = utt
        if NeuralVoice.enabled && neural.ready && !neural.sessionDisabled { writeNeural(utt) } else { writeApple(utt) }
    }

    /// Voz neuronal: el audio de la frase llega entero; se programa y se cierra la escritura.
    /// La siguiente frase se genera mientras suena esta, así que no hay pausas entre frases.
    private func writeNeural(_ utt: Utt) {
        let lang = textLanguage(utt.text) == "en" ? "en" : "es"
        let speed = min(1.5, max(0.7, Double(rate) / 0.52))
        neural.synthesize(utt.text, lang: lang, speed: speed) { [weak self] buf in
            guard let self, utt.gen == self.generation, !utt.written else { return }
            guard let buf, let out = self.convert(buf), out.frameLength > 0 else {
                logApp("Voz neuronal sin audio para la frase; uso la voz de Apple")
                self.writeApple(utt); return
            }
            utt.frames = out.frameLength
            utt.first = false
            // El aviso de "renderizado" llega cuando el buffer TERMINA; con la frase entera en un buffer el resaltado
            // arrancaría al final. Se programa una cabecera de 0.1 s con aviso y el resto detrás.
            let headFrames = min(out.frameLength, AVAudioFrameCount(self.outFormat.sampleRate / 10))
            let head = self.slice(out, from: 0, count: headFrames)
            let rest = out.frameLength > headFrames ? self.slice(out, from: headFrames, count: out.frameLength - headFrames) : nil
            self.player.scheduleBuffer(head ?? out, completionCallbackType: .dataRendered) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, utt.gen == self.generation else { return }
                    utt.renderStart = Date().addingTimeInterval(-Double(headFrames) / self.outFormat.sampleRate)
                    self.armIfReady(utt)
                }
            }
            if let rest, head != nil { self.player.scheduleBuffer(rest) }
            self.finishWrite(utt)
        }
    }

    /// Copia un tramo de un buffer mono float32.
    private func slice(_ buf: AVAudioPCMBuffer, from: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0, let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: count),
              let src = buf.floatChannelData?[0], let dst = out.floatChannelData?[0] else { return nil }
        memcpy(dst, src + Int(from), Int(count) * MemoryLayout<Float>.size)
        out.frameLength = count
        return out
    }

    private func writeApple(_ utt: Utt) {
        let text = utt.text
        let u = AVSpeechUtterance(string: text)
        u.voice = textLanguage(text) == "en" ? (voiceEN ?? voice) : voice
        u.rate = rate
        utt.utterance = u
        // Si la síntesis no entrega nada en 3 s, damos la locución por escrita para no bloquear la cola
        idleTimer?.invalidate()
        let first = Timer(timeInterval: 3.0, repeats: false) { [weak self] _ in
            logApp("La síntesis de voz no entregó audio; salto la frase")
            self?.finishWrite(utt)
        }
        RunLoop.main.add(first, forMode: .common)
        idleTimer = first
        synth.write(u) { [weak self] buf in
            guard let self else { return }
            DispatchQueue.main.async {
                guard utt.gen == self.generation, !utt.written else { return }
                guard let pcm = buf as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { self.finishWrite(utt); return }
                guard let out = self.convert(pcm) else { return }
                utt.frames += out.frameLength
                // Si dejan de llegar buffers, damos la locución por escrita
                self.idleTimer?.invalidate()
                let t = Timer(timeInterval: 0.7, repeats: false) { [weak self] _ in self?.finishWrite(utt) }
                RunLoop.main.add(t, forMode: .common)
                self.idleTimer = t
                if utt.first {
                    utt.first = false
                    self.player.scheduleBuffer(out, completionCallbackType: .dataRendered) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self, utt.gen == self.generation else { return }
                            utt.renderStart = Date()
                            self.armIfReady(utt)
                        }
                    }
                } else {
                    self.player.scheduleBuffer(out)
                }
            }
        }
    }

    /// Cuando se conocen inicio de reproducción y duración, arranca el resaltado y programa el final.
    private func armIfReady(_ utt: Utt) {
        guard let rs = utt.renderStart, let total = utt.total, !utt.finished else { return }
        highlightOwner = utt
        startHighlight(text: utt.text, offset: utt.offset, total: total, since: rs)
        schedule(at: rs.addingTimeInterval(total + 0.25)) { [weak self] in self?.finishPlayback(utt) }
    }

    private func finishPlayback(_ utt: Utt) {
        guard utt.gen == generation, !utt.finished else { return }
        utt.finished = true
        queued = max(0, queued - 1)
        if highlightOwner === utt {
            highlightTimer?.invalidate(); highlightTimer = nil
            highlightOwner = nil
        }
        if debugText { logApp("locución terminada") }
        onFinish?()
    }

    /// Fin de la escritura de la locución (por buffer vacío, por el delegado o por inactividad).
    private func finishWrite(_ utt: Utt) {
        guard writing, !utt.written, utt.gen == generation else { return }
        utt.written = true
        idleTimer?.invalidate(); idleTimer = nil
        let total = Double(utt.frames) / outFormat.sampleRate
        utt.total = total
        if debugText { logApp(String(format: "fin de escritura: %.1f s de audio", total)) }
        // Marcador de fin en el propio audio, por si llega antes que el cronómetro
        if let tail = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 2205) {
            tail.frameLength = 2205
            player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.finishPlayback(utt) }
            }
        }
        armIfReady(utt)
        writing = false
        current = nil
        writeNext()
    }

    // Delegado: el sistema avisa cuando terminó de generar la locución
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { if let c = self.current, c.utterance === u { self.finishWrite(c) } } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { if let c = self.current, c.utterance === u { self.finishWrite(c) } } }

    private var finishTimers: [Timer] = []
    private func schedule(at date: Date, _ action: @escaping () -> Void) {
        let t = Timer(timeInterval: max(0.01, date.timeIntervalSinceNow), repeats: false) { _ in action() }
        RunLoop.main.add(t, forMode: .common)
        finishTimers.append(t)
        finishTimers.removeAll { !$0.isValid }
    }

    /// Resalta palabra por palabra de forma proporcional al tiempo de la locución.
    private func startHighlight(text: String, offset: Int, total: Double, since: Date) {
        highlightTimer?.invalidate()
        if debugText { logApp(String(format: "resaltado: %.1f s para %d caracteres (offset %d)", total, (text as NSString).length, offset)) }
        guard total > 0 else { return }
        let ns = text as NSString
        let words = rx(#"\S+"#).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        guard !words.isEmpty else { return }
        var lastIdx = -1
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, Date().timeIntervalSince(since) / total)
            let charPos = Int(progress * Double(ns.length))
            var idx = words.firstIndex { NSMaxRange($0) > charPos } ?? words.count - 1
            idx = min(idx, words.count - 1)
            if idx != lastIdx {
                lastIdx = idx
                let r = words[idx]
                self.onRange?(NSRange(location: offset + r.location, length: r.length))
            }
            if progress >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        highlightTimer = t
    }
}

// MARK: - Sonidos propios, suaves, generados en el momento

final class Earcons {
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
    private var attached = false

    func attach(to engine: AVAudioEngine) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        attached = true
    }

    /// Secuencia de notas (frecuencia, duración) con envolvente suave.
    private func tone(_ notes: [(Double, Double)], volume: Float = 0.18) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.1 } + 0.05
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * sr)) else { return nil }
        buf.frameLength = buf.frameCapacity
        guard let ch = buf.floatChannelData?[0] else { return nil }
        var idx = 0
        for (freq, dur) in notes {
            let n = Int(dur * sr)
            for i in 0..<n where idx < Int(buf.frameLength) {
                let t = Double(i) / sr
                let attack = min(1, t / 0.012)
                let release = min(1, (dur - t) / 0.05)
                let env = Float(attack * release)
                // seno con un poco de segundo armónico para que suene cálido
                let v = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                ch[idx] = Float(v) * env * volume
                idx += 1
            }
        }
        return buf
    }

    private func play(_ buf: AVAudioPCMBuffer?) {
        guard attached, let buf, let eng = player.engine, eng.isRunning else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buf)
    }

    func listening() { play(tone([(659.3, 0.09), (880.0, 0.12)])) }       // sube: te escucho
    func sent() { play(tone([(587.3, 0.07), (493.9, 0.09)], volume: 0.14)) }   // baja: enviado
    func done() { play(tone([(880.0, 0.06)], volume: 0.1)) }                 // toque suave
    func reminder() { play(tone([(659.3, 0.11), (830.6, 0.11), (987.8, 0.2)], volume: 0.22)) }
}

// MARK: - Claude Code persistente (un proceso vivo que recibe órdenes en streaming)

final class PersistentClaude {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var model: String?
    private var contextStamp: Date?
    private let tools: String
    private let extraPrompt: String
    private let ownSession: Bool
    var kind: String { ownSession ? "Tareas" : "Conversación" }
    private var ownSid: String? = nil
    /// "low" / "medium" / "high": cuánto razona el modelo. Cambiarlo reinicia el proceso en la siguiente orden.
    var effort: String? = nil
    private var startedEffort: String? = nil

    /// - ownSession: la tarea usa una sesión propia y no toca la conversación principal.
    init(tools: String = allowedTools, extraPrompt: String = "", ownSession: Bool = false, effort: String? = nil) {
        self.tools = tools
        self.extraPrompt = extraPrompt
        self.ownSession = ownSession
        self.effort = effort
    }

    /// Cambia los callbacks del turno en curso (para pasar una orden a segundo plano).
    func rebind(onStatus: @escaping (String) -> Void, onText: @escaping (String) -> Void, completion: @escaping (String?, Bool) -> Void) {
        guard let t = turn else { return }
        turn = Turn(onStatus: onStatus, onText: onText, completion: completion, reply: t.reply, failed: t.failed)
    }
    var isBusy: Bool { turn != nil }
    private struct Turn {
        let onStatus: (String) -> Void
        let onText: (String) -> Void
        let completion: (String?, Bool) -> Void
        var reply: String? = nil
        var failed = false
    }
    private var turn: Turn?
    private var textEndedWithNewline = true   // para separar bloques de texto consecutivos
    private var draining = false               // turno interrumpido: se ignora todo hasta su "result"
    private var usageSeen: [String: UsageStore.Bucket] = [:]   // acumulado por modelo que ya contamos (el result trae totales de sesión)
    private var costSeen = 0.0
    private var drainTimeout: DispatchWorkItem?
    private var pendingSend: (() -> Void)?     // orden recibida mientras se vaciaba el turno interrumpido
    private var generation = 0
    private(set) var lastFailureWasExit = false
    var isRunning: Bool { process?.isRunning ?? false }
    var currentModel: String? { model }

    private func contextModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: contextFile.path))?[.modificationDate] as? Date
    }

    /// Arranca (o reinicia) el proceso con el modelo dado, retomando la sesión guardada.
    private func start(model: String?) {
        usageSeen = [:]; costSeen = 0
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudeBin)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--chrome",
                    "--allowedTools", tools, "--disallowedTools", disallowedTools,
                    "--append-system-prompt", systemPrompt() + extraPrompt]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        startedEffort = effort
        if ownSession {
            if let sid = ownSid { args += ["--resume", sid] }
            else { let sid = UUID().uuidString.lowercased(); ownSid = sid; args += ["--session-id", sid] }
        } else if let sid = readSession() { args += ["--resume", sid] }
        else {
            let sid = UUID().uuidString.lowercased()
            args += ["--session-id", sid]
            writeSession(sid)
            touchSessionTime()
            logConv("--- sesión \(sid) ---")
        }
        p.arguments = args
        p.currentDirectoryURL = baseDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeDir.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if effort == "low" { env["MAX_THINKING_TOKENS"] = "1024" }   // rápido: poco razonamiento interno
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { logApp("claude stderr: \(err.prefix(600))") }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                logApp("El proceso de Claude terminó (código \(proc.terminationStatus))")
                self.process = nil; self.stdinHandle = nil
                if let t = self.turn { self.turn = nil; self.lastFailureWasExit = true; t.completion(t.reply, true) }
            }
        }
        do { try p.run() } catch { logApp("No pude lanzar claude: \(error)"); return }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        self.model = model
        contextStamp = contextModified()
        logApp("Claude Code persistente iniciado (modelo \(model ?? "por defecto"))")
        let h = outPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                buffer.append(d)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer = Data(buffer[(nl + 1)...])
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.handle(obj)
                    }
                }
            }
        }
    }

    func stop() {
        if process != nil { logApp("Apago el proceso de Claude Code") }
        generation += 1
        draining = false; drainTimeout?.cancel(); drainTimeout = nil; pendingSend = nil
        if let t = turn { turn = nil; t.completion(t.reply, true) }
        try? stdinHandle?.close()
        if let p = process, p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        }
        process = nil
        stdinHandle = nil
    }

    /// Cancela la orden en curso. El proceso se reinicia en la siguiente orden retomando la sesión.
    func cancel() {
        turn = nil
        stop()
    }

    /// Interrumpe el turno en curso sin apagar el proceso (Claude Code responde en ~30 ms y sigue vivo,
    /// así la siguiente orden no paga el arranque de 2 a 4 s). Si no responde en 4 s, se reinicia.
    func interruptTurn() {
        guard isRunning, turn != nil, let stdin = stdinHandle else { turn = nil; return }
        turn = nil
        draining = true
        let msg: [String: Any] = ["type": "control_request", "request_id": "int-\(Int(Date().timeIntervalSince1970 * 1000))", "request": ["subtype": "interrupt"]]
        if var data = try? JSONSerialization.data(withJSONObject: msg) { data.append(10); stdin.write(data) }
        logApp("Interrumpo el turno de Claude Code (el proceso sigue vivo)")
        drainTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.draining else { return }
            logApp("La interrupción no respondió; reinicio el proceso")
            let pending = self.pendingSend
            self.stop()
            pending?()
        }
        drainTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    /// Arranca el proceso por adelantado para que la primera orden no espere.
    func prewarm(model: String?) {
        guard !isRunning else { return }
        if sessionIsStale() { clearSession() }
        start(model: model)
    }

    func send(_ text: String, model: String?, onStatus: @escaping (String) -> Void, onText: @escaping (String) -> Void, completion: @escaping (String?, Bool) -> Void) {
        if draining {
            // El turno interrumpido aún no cerró: la orden espera a su "result" (milisegundos)
            pendingSend = { [weak self] in self?.send(text, model: model, onStatus: onStatus, onText: onText, completion: completion) }
            return
        }
        var text = text
        let contextChanged = contextStamp != contextModified()
        if !isRunning || model != self.model || effort != startedEffort || (!ownSession && readSession() == nil) {
            if isRunning { logApp("Reinicio de Claude Code: \(model != self.model ? "cambio de modelo" : effort != startedEffort ? "cambio de esfuerzo" : "sesión nueva")") }
            start(model: model)
        } else if contextChanged, let ctx = try? String(contentsOf: contextFile, encoding: .utf8) {
            // Sin reiniciar: el contexto actualizado viaja con la orden
            contextStamp = contextModified()
            text += "\n\n[Contexto personal actualizado]\n" + String(ctx.suffix(3000))
        }
        guard let stdin = stdinHandle else { completion(nil, true); return }
        turn = Turn(onStatus: onStatus, onText: onText, completion: completion)
        textEndedWithNewline = true
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { completion(nil, true); return }
        data.append(10)
        stdin.write(data)
    }

    /// Inyecta una instrucción en el turno en curso (Claude la atiende en la siguiente pausa entre acciones).
    /// Devuelve false si no hay turno en curso; en ese caso usa send().
    func steer(_ text: String) -> Bool {
        guard isRunning, turn != nil, let stdin = stdinHandle else { return false }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return false }
        data.append(10)
        stdin.write(data)
        logApp("Instrucción inyectada en el turno en curso")
        return true
    }

    /// Contabiliza un "result". Los tokens salen del bloque `usage` (es del turno). El costo, de la diferencia de
    /// `total_cost_usd` (acumulado de sesión); en el primer result del proceso el acumulado incluye la historia
    /// retomada con --resume, así que se estima proporcionalmente al peso de los tokens del turno.
    private func account(_ obj: [String: Any]) {
        guard let usage = obj["usage"] as? [String: Any] else { return }
        var d = UsageStore.Bucket()
        d.input = usage["input_tokens"] as? Int ?? 0
        d.output = usage["output_tokens"] as? Int ?? 0
        d.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        d.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        d.turns = 1
        let mu = obj["modelUsage"] as? [String: [String: Any]] ?? [:]
        let totalCost = obj["total_cost_usd"] as? Double ?? 0
        // Modelo del turno: el que creció desde el result anterior; si no, el de más salida acumulada
        var model: String? = nil; var best = 0
        for (m, v) in mu {
            let out = v["outputTokens"] as? Int ?? 0
            if out - (usageSeen[m]?.output ?? 0) > best { best = out - (usageSeen[m]?.output ?? 0); model = m }
        }
        if model == nil { model = mu.max { ($0.value["outputTokens"] as? Int ?? 0) < ($1.value["outputTokens"] as? Int ?? 0) }?.key ?? self.model ?? "Claude" }
        let weight: (UsageStore.Bucket) -> Double = { Double($0.input) + 5 * Double($0.output) + 0.1 * Double($0.cacheRead) + 1.25 * Double($0.cacheWrite) }
        if usageSeen.isEmpty {
            var cum = UsageStore.Bucket()
            for v in mu.values {
                cum.input += v["inputTokens"] as? Int ?? 0; cum.output += v["outputTokens"] as? Int ?? 0
                cum.cacheRead += v["cacheReadInputTokens"] as? Int ?? 0; cum.cacheWrite += v["cacheCreationInputTokens"] as? Int ?? 0
            }
            let w = weight(cum)
            d.cost = w > 0 ? totalCost * min(1, weight(d) / w) : 0
        } else {
            d.cost = max(0, totalCost - costSeen)
        }
        costSeen = max(costSeen, totalCost)
        for (m, v) in mu {
            var b = UsageStore.Bucket()
            b.input = v["inputTokens"] as? Int ?? 0; b.output = v["outputTokens"] as? Int ?? 0
            b.cacheRead = v["cacheReadInputTokens"] as? Int ?? 0; b.cacheWrite = v["cacheCreationInputTokens"] as? Int ?? 0
            usageSeen[m] = b
        }
        if usageSeen.isEmpty { usageSeen["_"] = UsageStore.Bucket() }
        UsageStore.shared.add(model: UsageStore.modelName(model ?? "Claude"), kind: kind, d)
    }

    private func handle(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        if type == "result" { account(obj) }
        if draining {
            // Restos del turno interrumpido: solo nos interesa su cierre
            if type == "result" {
                draining = false; drainTimeout?.cancel(); drainTimeout = nil
                let pending = pendingSend; pendingSend = nil
                pending?()
            }
            return
        }
        if type == "stream_event", let ev = obj["event"] as? [String: Any], (ev["type"] as? String) == "content_block_start",
           let block = ev["content_block"] as? [String: Any], (block["type"] as? String) == "text" {
            // Texto nuevo tras una herramienta: salto de línea para que no se pegue a la frase anterior (ni a un HITO)
            if !textEndedWithNewline { textEndedWithNewline = true; turn?.onText("\n") }
        } else if type == "stream_event", let ev = obj["event"] as? [String: Any],
           (ev["type"] as? String) == "content_block_delta",
           let delta = ev["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
           let t = delta["text"] as? String, !t.isEmpty {
            textEndedWithNewline = t.hasSuffix("\n")
            turn?.onText(t)
        } else if type == "assistant", let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                turn?.onStatus(toolLabel(name, input))
            }
        } else if type == "result" {
            let reply = obj["result"] as? String
            let failed = (obj["is_error"] as? Bool) ?? false
            if failed {
                let empty = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // Error sin texto = casi siempre "No conversation found with session ID" (va por stderr): la sesión guardada
                // ya no existe. Se descarta para que la siguiente orden (o el reintento) arranque una sesión nueva.
                lastFailureWasExit = empty
                if empty && !ownSession { clearSession(); logApp("Claude devolvió error vacío: descarto la sesión guardada") }
                else { logApp("Claude devolvió error: \((reply ?? "").prefix(200))") }
                if empty && turn == nil { stop() }
            }
            if let t = turn { turn = nil; t.completion(reply, failed) }
        }
    }
}

// MARK: - Controlador principal

final class Controller: NSObject {
    enum State { case idle, listening, thinking, speaking }
    let overlay = Overlay()
    let listener = Listener()
    let speaker = Speaker()
    var claude = PersistentClaude()
    let earcons = Earcons()
    let tasks = TaskManager()
    let tasksPanel = TasksPanel()
    let routines = Routines()
    private var pendingTask: LongTask? = nil          // esperando tu "adelante"
    private var promoteWork: DispatchWorkItem? = nil  // pasa a segundo plano si tarda
    private var announceQueue: [(Date, String)] = []
    private var panelDismissed = false
    var taskEffort: String { UserDefaults.standard.string(forKey: "taskEffort") ?? "medium" }
    var showTasksPanel: Bool { UserDefaults.standard.object(forKey: "showTasksPanel") == nil ? true : UserDefaults.standard.bool(forKey: "showTasksPanel") }
    let media = MediaControl()
    let reminders = Reminders()
    let input = InputPanel()
    let settingsWindow = SettingsWindow()
    let historyWindow = HistoryWindow()
    var followUpSeconds: Int { UserDefaults.standard.object(forKey: "followUpSeconds") as? Int ?? 5 }
    var sendSound: Bool { UserDefaults.standard.object(forKey: "sendSound") == nil ? true : UserDefaults.standard.bool(forKey: "sendSound") }
    private var typedReply = false      // orden escrita: responde en pantalla, sin voz
    /// Voz silenciada por el usuario: Claude sigue escribiendo en el widget pero no habla. Persistente.
    var muted: Bool { UserDefaults.standard.bool(forKey: "mutedVoice") }
    private var silent: Bool { typedReply || muted }
    private var muteMenuItem: NSMenuItem?
    private var usageLine: NSMenuItem!
    private func checkUsageAlert() {
        let limit = UsageStore.alertUSD
        guard limit > 0 else { return }
        let month = String(UsageStore.key().prefix(7))
        let cost = UsageStore.shared.month.0.cost
        guard cost >= limit, UserDefaults.standard.string(forKey: "usageAlertedMonth") != month else { return }
        UserDefaults.standard.set(month, forKey: "usageAlertedMonth")
        let msg = "Este mes ya llevas \(UsageStore.money(cost)) de uso, por encima del aviso de \(UsageStore.money(limit))."
        logConv("(uso) \(msg)")
        let content = UNMutableNotificationContent(); content.title = "Uso de Claude Voice"; content.body = msg
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        announce(msg)
    }
    private func updateUsageLine() {
        let t = UsageStore.shared.today, m = UsageStore.shared.month.0
        usageLine?.title = "Uso hoy: \(UsageStore.tokens(t.tokens)) tokens · \(UsageStore.money(t.cost))   (mes: \(UsageStore.money(m.cost)))"
    }
    private var remindersLine: NSMenuItem!
    private var listenMenuItem: NSMenuItem?
    private var typeMenuItem: NSMenuItem?
    private var state: State = .idle { didSet { if (oldValue == .idle) != (state == .idle) { updateEscapeHotkey() } } }
    private var followUp = false
    private var commandText = ""
    private var segmentPrefix = ""   // texto ya reconocido antes de un reinicio automático
    private var lastRawText = ""     // última transcripción cruda, para detectar cuando el reconocedor empieza de cero
    private var rawNow = ""          // última transcripción recibida, en cualquier estado
    private var baselineRaw = ""     // texto que ya existía al empezar a escuchar sin reiniciar (se descarta)
    private var rawByLang: [String: String] = [:]      // última transcripción de cada reconocedor
    private(set) var activeLang = "es"                  // reconocedor cuyas transcripciones se usan
    private var replyLang = "es"                        // idioma en que se contestan las frases fijas
    private var lastChange = Date()
    private var listenStart = Date()
    private var tick: Timer?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyRef2: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?   // Esc solo mientras Claude escucha, piensa o habla
    private var lastEscape = Date.distantPast    // doble Esc rápido cancela; uno solo puede ser para otra app
    private var smoothLevel: CGFloat = 0
    private var overlayLastReply = ""
    private var screenshotToDelete: URL? = nil
    private var streamText = ""        // texto de la respuesta recibido hasta ahora
    private var streamSpokenUpTo = 0   // cuántos caracteres ya se encolaron para hablar
    private var processDone = true
    private var currentCmd = ""
    private var speakStart = Date()
    private var speakWatchdog: DispatchWorkItem?
    private var speakThenIdle = false

    /// Si el audio se atasca y nunca avisa que terminó, seguimos de todos modos.
    private func armSpeakWatchdog() {
        speakWatchdog?.cancel()
        let words = max(streamText.split(separator: " ").count, overlayLastReply.split(separator: " ").count)
        let expected = Double(words) / 2.2 + 8
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .speaking, self.processDone else { return }
            logApp("El habla no terminó a tiempo; continúo")
            self.speaker.onFinish = nil
            self.speaker.stop()
            if self.speakThenIdle { self.goIdle() } else { self.finishSpeaking() }
        }
        speakWatchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(expected, Date().timeIntervalSince(speakStart) + 8), execute: w)
    }
    private var speakBaseline: CGFloat = 0
    private var loudSince: Date?

    func start() {
        setupMenu()
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else { self.fail("Sin permiso de reconocimiento de voz. Actívalo en Ajustes > Privacidad."); return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else { self.fail("Sin permiso de micrófono. Actívalo en Ajustes > Privacidad."); return }
                        self.begin()
                    }
                }
            }
        }
    }

    private func fail(_ msg: String) {
        logApp(msg)
        statusLine.title = msg
        overlay.set("Claude Voice", msg, .idle)
        overlay.show()
    }

    private func begin() {
        settingsWindow.controller = self
        historyWindow.controller = self
        tasks.onChange = { [weak self] in self?.refreshTasksPanel() }
        tasks.announce = { [weak self] text in self?.announce(text) }
        tasksPanel.onCancelId = { [weak self] id in
            guard let self, let t = self.tasks.tasks.first(where: { $0.id == id }) else { return }
            self.tasks.cancel(t)
        }
        tasksPanel.onClose = { [weak self] in self?.panelDismissed = true }
        tasksPanel.onClear = { [weak self] in self?.tasks.clearFinished() }
        overlay.onStop = { [weak self] in self?.cancelPressed() }
        overlay.onMute = { [weak self] in self?.toggleMute(nil) }
        overlay.onPause = { [weak self] in self?.pausePressed() }
        overlay.onTap = { [weak self] in self?.manualListen() }
        listener.beforeStart = { [speaker, earcons] engine in speaker.attach(to: engine); earcons.attach(to: engine) }
        input.onSubmit = { [weak self] t in self?.typedCommand(t) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        reminders.canFire = { [weak self] in self?.state == .idle }
        reminders.onFire = { [weak self] r in self?.fireReminder(r) }
        routines.canFire = { [weak self] in self?.state == .idle && (self?.tasks.running.isEmpty ?? true) }
        routines.onFire = { [weak self] r in self?.fireRoutine(r) }
        listener.vocab = loadVocab()
        listener.onText = { [weak self] t, lang in self?.handleText(t, lang: lang) }
        listener.onAutoRestart = { [weak self] in
            guard let self else { return }
            logApp("Reinicio automático del reconocedor en estado \(self.state), texto hasta ahora: \"\(self.commandText)\"")
            guard self.state == .listening else { return }
            // Conserva lo dicho hasta ahora y sigue escuchando sin exigir la palabra de activación
            let sofar = self.commandText.trimmingCharacters(in: .whitespaces)
            self.segmentPrefix = sofar.isEmpty ? "" : sofar + " "
            self.followUp = true
            self.baselineRaw = ""
            self.rawNow = ""
            self.rawByLang = [:]
        }
        listener.onLevel = { [weak self] l in
            guard let self else { return }
            self.smoothLevel = self.smoothLevel * 0.6 + l * 0.4
            self.overlay.logo.level = self.smoothLevel
            self.checkLoudInterrupt()
        }
        NSAppleScript(source: "set volume input volume 100")?.executeAndReturnError(nil)
        do { try listener.startEngine() } catch { fail("No pude abrir el micrófono: \(error.localizedDescription)"); return }
        listener.restart()
        tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(tick!, forMode: .common)
        setupHotkey()
        statusLine.title = "Esperando \"hey claude\""
        updateRemindersLine()
        logApp("Claude Voice listo")
        speaker.neural.start()
        let tiers = loadModelTiers()
        let normal = tiers["normal"] ?? "sonnet"
        claude.prewarm(model: normal == "default" ? nil : normal)
        // Aviso breve de arranque
        overlay.set("Claude Voice", "Di \"hey claude\" o presiona ⌥⌘C", .idle)
        overlay.show()
        overlay.hide(after: 4)
    }

    // MARK: Texto reconocido

    private func handleText(_ incoming: String, lang: String) {
        rawByLang[lang] = incoming
        // Elegir idioma: en reposo, el que detecte la activación; escuchando, el que más pinta tenga
        var switched = false
        if state == .idle {
            if lang != activeLang, commandAfterWake(incoming) != nil, commandAfterWake(rawByLang[activeLang] ?? "") == nil {
                activeLang = lang; switched = true
            }
        } else if state == .listening {
            let mine = languageScore(rawByLang[activeLang] ?? "")
            let other = activeLang == "es" ? "en" : "es"
            let theirs = languageScore(rawByLang[other] ?? "")
            let words = (rawByLang[other] ?? "").split(separator: " ").count
            let preferOther = activeLang == "es" ? (theirs < mine - 1 && theirs < 0) : (theirs > mine + 1 && theirs > 0)
            if preferOther && words >= 2 { activeLang = other; switched = true; logApp("Cambio de idioma a \(other)") }
        }
        guard lang == activeLang || switched else { return }
        let text = rawByLang[activeLang] ?? incoming
        if switched { lastRawText = ""; baselineRaw = ""; segmentPrefix = ""; commandText = "" }
        lastChange = Date()
        rawNow = text
        switch state {
        case .idle:
            if let cmd = commandAfterWake(text) {
                commandText = cmd
                enterListening(followUp: false)
            }
        case .listening:
            let before = commandText
            // El reconocedor local empieza una transcripción nueva tras una pausa (el texto se encoge de golpe).
            // Conservamos lo dicho y seguimos sin exigir otra vez la palabra de activación.
            // También cuenta como segmento nuevo que el texto ya no empiece igual (p. ej. "Hey Claude" → "Quiero que..."):
            // con una activación corta el texto nuevo no es más corto y antes se perdía toda la orden.
            let shrank = lastRawText.count > 6 && text.count * 2 < lastRawText.count
            let firstNew = normalize(text).split(separator: " ").first.map(String.init) ?? ""
            let firstOld = normalize(lastRawText).split(separator: " ").first.map(String.init) ?? ""
            let sofarNorm = normalize(commandText).trimmingCharacters(in: .whitespaces)
            let restartedByStart = !firstNew.isEmpty && !firstOld.isEmpty && firstNew != firstOld
                && (sofarNorm.isEmpty || !normalize(text).hasPrefix(sofarNorm))
            if shrank || restartedByStart {
                let sofar = commandText.trimmingCharacters(in: .whitespaces)
                segmentPrefix = sofar.isEmpty ? "" : sofar + " "
                followUp = true
                baselineRaw = ""
                logApp("Nuevo segmento del reconocedor (\(shrank ? "más corto" : "otro inicio")); conservo: \"\(sofar)\"")
            }
            lastRawText = text
            // Sin reiniciar el reconocedor: descarta las palabras que ya existían al empezar a escuchar
            var fresh = text
            if followUp && !baselineRaw.isEmpty {
                let bw = baselineRaw.split(separator: " ").count
                let words = text.split(separator: " ")
                fresh = words.count > bw ? words.dropFirst(bw).joined(separator: " ") : ""
            }
            if followUp { fresh = stripReplyEcho(fresh) }
            if followUp, let afterWake = commandAfterWake(fresh) { fresh = afterWake }   // "hey claude" repetido a mitad de orden
            if followUp { commandText = joinWithoutOverlap(segmentPrefix, fresh) } else if let cmd = commandAfterWake(text) { commandText = cmd }
            commandText = fixTitleCase(commandText)
            if debugText && commandText != before { logApp("orden parcial (seguimiento=\(followUp)): \"\(commandText)\"") }
            overlay.set("Escuchando…", commandText.isEmpty ? "Te escucho" : commandText, .listening)
        case .speaking:
            guard lang == activeLang else { return }
            let n = normalize(text)
            let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            // Palabras que oye y que NO están en lo que Claude está leyendo = el usuario está hablando
            let own = Set(normalize(overlayLastReply).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let foreign = words.filter { $0.count > 2 && !own.contains($0) && Int($0) == nil }
            if !foreign.isEmpty { lastForeignSpeechAt = Date() }   // el reconocedor oyó algo que no es la voz de Claude
            let userTalking = foreign.count >= 2 && Double(foreign.count) / Double(max(words.count, 1)) >= 0.5
            let stopWordIsForeign = matches(stopRegex, n) && words.contains { !own.contains($0) && matches(stopRegex, $0) }
            if (words.count <= 3 && stopWordIsForeign) || commandAfterWake(text) != nil || userTalking {
                // Semilla: las palabras originales (con acentos) que no son de Claude, quitando la de activación
                var tokens = text.split(separator: " ").map(String.init).filter { !own.contains(normalize($0).trimmingCharacters(in: .punctuationCharacters)) }
                if let afterWake = commandAfterWake(tokens.joined(separator: " ")) { tokens = afterWake.split(separator: " ").map(String.init) }
                var seed = tokens.joined(separator: " ")
                if matches(stopRegex, normalize(seed)) && tokens.count <= 2 { seed = "" }
                logApp(debugText ? "Interrumpido por el usuario: \(text) -> semilla \"\(seed)\"" : "Interrumpido por el usuario")
                interrupt(seed: seed)
            }
        case .thinking:
            // "hey claude" mientras piensa: cancela y escucha la orden nueva
            if let cmd = commandAfterWake(text) {
                logApp("Activación durante el procesamiento")
                if cmd.isEmpty {
                    // Solo "hey claude": corta la orden y escucha
                    claude.interruptTurn(); processDone = true
                    logConv("< (cancelado por nueva orden)")
                    enterListening(followUp: true)
                } else if claude.steer("El usuario dice ahora: \"\(cmd)\". Deja lo que estabas haciendo si ya no aplica y atiende esto.") {
                    logConv("> [inyectada] \(cmd)")
                    overlay.set("Pensando · \(currentModelName)", cmd, .thinking)
                } else {
                    claude.interruptTurn(); processDone = true
                    enterListening(followUp: true)
                    segmentPrefix = ""; commandText = cmd; lastChange = Date(); overlay.set("Escuchando…", cmd, .listening)
                }
            }
        }
    }

    private func onTick() {
        // Prueba: un archivo .say con texto hace que Claude lo lea frase por frase como una respuesta
        let sayFile = baseDir.appendingPathComponent(".say")
        if debugText, state == .idle, let t = try? String(contentsOf: sayFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: sayFile)
            typedReply = false
            state = .thinking
            streamText = ""; streamSpokenUpTo = 0; processDone = false
            overlay.show()
            beginStreamingSpeech()
            for sentence in t.split(whereSeparator: { $0 == "\n" }) {
                streamText += String(sentence).trimmingCharacters(in: .whitespaces) + " "
                overlay.set("Claude · prueba", streamText, .speaking)
                flushSentences(final: false)
            }
            processDone = true
            flushSentences(final: true)
            if !speaker.isSpeaking { finishSpeaking() }
        }
        if FileManager.default.fileExists(atPath: triggerFile.path) {
            try? FileManager.default.removeItem(at: triggerFile)
            manualListen()
        }
        let typeFile = baseDir.appendingPathComponent(".type")
        if debugText, state == .idle, let t = try? String(contentsOf: typeFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: typeFile)
            typedCommand(t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let quiet = Date().timeIntervalSince(lastChange)
        switch state {
        case .listening:
            let cmd = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty && quiet > 1.9 {
                commit(cmd)
            } else if cmd.isEmpty && !followUp && quiet > 1.9 && Date().timeIntervalSince(listenStart) > 4,
                      case let heard = (commandAfterWake(rawNow) ?? rawNow).trimmingCharacters(in: .whitespacesAndNewlines),
                      heard.split(separator: " ").count >= 2 {
                // Se oyeron palabras pero ninguna se aceptó como orden: mejor tomarlas que quedarse en "Te escucho"
                logApp("Orden sin activación reconocida; tomo lo oído: \"\(heard)\"")
                commit(heard)
            } else if cmd.isEmpty && Date().timeIntervalSince(listenStart) > (followUp ? Double(followUpSeconds) : 8) {
                if overlay.isHovered { listenStart = Date(); return }   // está leyendo: sigue escuchando
                logApp("Nadie habló, vuelvo a reposo")
                goIdle()
            }
        case .idle:
            // Reinicia la transcripción de vez en cuando para que no se haga lenta
            if quiet > 4 && Date().timeIntervalSince(listener.lastRestart) > 120 { listener.restart() }
            weeklyMemorySummaryIfDue()
        default:
            break
        }
    }

    // MARK: Estados

    private func enterListening(followUp: Bool) {
        listener.setEchoActive(false)
        overlay.showPause(false)
        typedReply = false
        state = .listening
        self.followUp = followUp
        segmentPrefix = ""
        // En seguimiento no reiniciamos la transcripción (perdería la primera palabra); ignoramos lo previo
        baselineRaw = followUp ? rawNow : ""
        lastRawText = followUp ? rawNow : ""
        listenStart = Date()
        lastChange = Date()
        logApp(followUp ? "Escuchando (sin activación)" : "Activado por voz")
        media.pauseIfPlaying()
        if followUp { commandText = "" }
        else { earcons.listening() }
        overlay.set("Escuchando…", commandText.isEmpty ? "Te escucho" : commandText, .listening)
        overlay.show()
        statusLine.title = "Escuchando"
        setIcon("mic.circle.fill")
    }

    private func commit(_ cmdRaw: String) {
        var cmd = fixTitleCase(cmdRaw)
        let corrected = applyCorrections(cmd)
        if corrected != cmd { logApp("Corrección de dictado: \"\(cmd)\" → \"\(corrected)\""); cmd = corrected }
        replyLang = languageScore(cmd) < 0 ? "en" : "es"
        logApp("Enviando orden [\(replyLang)]: \"\(cmd)\"")
        lastRawText = ""
        resetRecognizerText()
        listener.restart()   // sigue escuchando por si dices "hey claude" mientras piensa
        commandText = ""
        let n = normalize(cmd).trimmingCharacters(in: .punctuationCharacters)
        // Tareas largas: confirmación pendiente, estado, cancelación o detección
        if let draft = pendingTask {
            pendingTask = nil
            if matches(denyRegex, n) {
                tasks.finish(draft, status: .cancelled, message: nil)
                speak(replyLang == "en" ? "Okay, I won't do it." : "Vale, no lo hago.", thenIdle: true); return
            }
            // Cualquier otra respuesta cuenta como "sí": si además trae una indicación, se la pasamos
            startTask(draft, extra: matches(confirmRegex, n) && n.split(separator: " ").count <= 3 ? nil : cmd)
            return
        }
        if matches(taskStatusRegex, n) {
            let running = tasks.running
            if running.isEmpty { speak(replyLang == "en" ? "I have no tasks running." : "No tengo ninguna tarea en curso.", thenIdle: false); return }
            let parts = running.map { t -> String in
                let last = t.lastMilestone.isEmpty ? (replyLang == "en" ? "just started" : "recién empieza") : t.lastMilestone
                return "\(t.title): \(last), \(t.elapsedText)"
            }
            speak(parts.joined(separator: ". "), thenIdle: false); return
        }
        if matches(taskCancelRegex, n) {
            if tasks.running.isEmpty { speak(replyLang == "en" ? "There's nothing to cancel." : "No hay ninguna tarea que cancelar.", thenIdle: false); return }
            tasks.cancelAll()
            speak(replyLang == "en" ? "Cancelled." : "Cancelada.", thenIdle: false); return
        }
        if let t = taskAddressed(by: n) {
            steerTask(t, with: cmd); return
        }
        if matches(longTaskRegex, n) {
            planTask(cmd, n: n); return
        }
        if matches(onlyStopRegex, n) {
            // "para", "espera": no hay orden; solo calla y vuelve a reposo
            logConv("(sin orden: \(cmd))")
            goIdle(); return
        }
        if matches(endRegex, n) && matches(endStrongRegex, n) {
            let en = replyLang == "en"
            speak(en ? (n.contains("thank") ? "You're welcome." : "Okay.") : (n.contains("gracias") ? "De nada." : "Listo."), thenIdle: true); return
        }
        if matches(newConvRegex, n) {
            claude.stop()
            clearSession()
            logConv("--- nueva conversación ---")
            speak(replyLang == "en" ? "Starting fresh." : "Empezamos de cero.", thenIdle: false); return
        }
        if let m = typeRegex.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            // Dictado: teclea el texto (con acentos del original) en la app activa
            let normCmd = normalize(cmd)
            var text = (n as NSString).substring(with: m.range(at: 2))
            if (normCmd as NSString).length == (cmd as NSString).length { text = (cmd as NSString).substring(with: m.range(at: 2)) }
            logConv("> (dictado) \(text)")
            if typeIntoFrontApp(text) { speak(replyLang == "en" ? "Done." : "Listo.", thenIdle: false) }
            else { speak(replyLang == "en" ? "To type for you I need Accessibility access. I opened the request in System Settings." : "Para escribir por ti necesito el permiso de Accesibilidad. Te abrí la solicitud en Ajustes del Sistema.", thenIdle: false) }
            return
        }
        if matches(rx(#"^(leeme|lee|dime|cuales son|que) (las |mis )?notificaciones|^(que notificaciones tengo|tengo notificaciones|read my notifications|what notifications do i have|any notifications)\b"#), n) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            let out = shell("/bin/bash", [baseDir.appendingPathComponent("tareas/mensajes.sh").path, "notificaciones"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let answer = lines.isEmpty || out.hasPrefix("Sin ") ? (replyLang == "en" ? "No notifications right now." : "No hay notificaciones a la vista.")
                : (replyLang == "en" ? "You have \(lines.count): " : "Tienes \(lines.count): ") + lines.prefix(5).joined(separator: ". ") + "."
            logConv("< \(answer)")
            speak(answer, thenIdle: false); return
        }
        if let m = rx(#"^(leeme|lee|dime|cual es|que dice) (el ultimo mensaje|los ultimos (\d+) mensajes|el ultimo (whatsapp|imessage|sms|texto))(?: de (.+))?$|^(read|what's) (my last message|the last message|my last (\d+) messages)(?: from (.+))?$"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            func g(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : (n as NSString).substring(with: m.range(at: i)) }
            let count = Int(g(3)) ?? Int(g(8)) ?? 1
            let who = g(5).isEmpty ? g(9) : g(5)
            let out = shell("/bin/bash", [baseDir.appendingPathComponent("tareas/mensajes.sh").path, "mensajes", "\(count)", who]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: String
            if out.hasPrefix("No puedo leer") { answer = replyLang == "en" ? "I can't read Messages yet: give Claude Voice Full Disk Access in System Settings, Privacy and Security." : "Todavía no puedo leer Mensajes: dale a Claude Voice Acceso total al disco en Ajustes del Sistema, Privacidad y seguridad." }
            else if out.hasPrefix("No hay") { answer = out }
            else {
                let items = out.split(separator: "\n").map { line -> String in
                    let p = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
                    return p.count == 3 ? "\(p[1]): \(p[2])" : String(line)
                }
                answer = items.joined(separator: ". ")
            }
            logConv("< \(answer.prefix(300))")
            speak(answer, thenIdle: false); return
        }
        if let answer = macControl(n, original: cmd) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            logConv("< \(answer)")
            speak(answer, thenIdle: false); return
        }
        if let m = historyRegex.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let topic = (n as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            let answer = searchHistory(topic: topic, query: n)
            UsageStore.shared.countLocal()
            logConv("> (historial) \(cmd)")
            logConv("< \(answer)")
            speak(answer, thenIdle: false); return
        }
        if matches(muteOnRegex, n) || matches(muteOffRegex, n) {
            let on = matches(muteOnRegex, n)
            logConv("> (local) \(cmd)")
            setMuted(on)
            let msg = on ? (replyLang == "en" ? "Okay, text only from now on." : "Listo, desde ahora solo escribo.")
                         : (replyLang == "en" ? "Voice is back on." : "Listo, vuelvo a hablar.")
            logConv("< \(msg)")
            speak(msg, thenIdle: true); return
        }
        if matches(rx(#"^(que sabes de mi|que sabes sobre mi|que has aprendido de mi|que aprendiste de mi|que recuerdas de mi|que tienes en (tu )?memoria|what do you know about me|what have you learned about me|what do you remember about me)\b"#), n) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            let facts = MemoryFile.facts()
            let fresh = MemoryFile.newSince(days: 7)
            var msg: String
            if facts.isEmpty { msg = replyLang == "en" ? "Nothing yet. Tell me things with \"remember that\"." : "Todavía nada. Dime cosas con \"recuerda que\"." }
            else {
                msg = replyLang == "en" ? "I know \(facts.count) things about you." : "Sé \(facts.count) cosas de ti."
                if !fresh.isEmpty { msg += replyLang == "en" ? " New this week: " : " Nuevas esta semana: "; msg += fresh.prefix(3).joined(separator: "; ") + "." }
                else { msg += replyLang == "en" ? " The latest: " : " Las últimas: "; msg += facts.suffix(3).joined(separator: "; ") + "." }
                msg += replyLang == "en" ? " You can review them in Settings, Memory." : " Puedes revisarlas en Ajustes, Memoria."
            }
            logConv("< \(msg)")
            speak(msg, thenIdle: false); return
        }
        if let instant = instantAnswer(n) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            logConv("< \(instant)")
            speak(instant, thenIdle: false); return
        }
        if let r = Routines.parse(n, original: cmd) {
            routines.add(r)
            UsageStore.shared.countLocal()
            logConv("(rutina) \(r.whenText): \(r.text)")
            let msg = replyLang == "en" ? "Done. \(r.whenText), I'll do: \(r.text)." : "Listo. \(r.whenText.prefix(1).capitalized + r.whenText.dropFirst()), haré: \(r.text)."
            logConv("< \(msg)")
            speak(msg, thenIdle: false); return
        }
        if matches(rx(#"^(que rutinas tengo|mis rutinas|rutinas|lista(me)? las rutinas|what routines do i have|my routines)\b"#), n) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            if routines.items.isEmpty { speak(replyLang == "en" ? "You have no routines. Say, for example: every morning at 8 tell me the weather." : "No tienes rutinas. Di por ejemplo: cada mañana a las 8 dime el clima.", thenIdle: false); return }
            let list = routines.items.map { "\($0.whenText): \($0.text)" }.joined(separator: ". ")
            let msg = (replyLang == "en" ? "You have \(routines.items.count): " : "Tienes \(routines.items.count): ") + list + "."
            logConv("< \(msg)")
            speak(msg, thenIdle: false); return
        }
        if let m = rx(#"^(borra|elimina|quita|cancela|delete|remove) (la |the )?rutina( de las (\d{1,2})| de (.+)| (.+))?$"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            UsageStore.shared.countLocal()
            logConv("> (local) \(cmd)")
            let hour = m.range(at: 4).location != NSNotFound ? Int((n as NSString).substring(with: m.range(at: 4))) : nil
            let topic = [5, 6].compactMap { m.range(at: $0).location != NSNotFound ? (n as NSString).substring(with: m.range(at: $0)) : nil }.first
            let victim = routines.items.first { r in
                if let hour { return r.hour == hour || r.hour == hour + 12 }
                if let topic { let w = normalize(topic).split(separator: " ").filter { $0.count > 3 }; return w.contains { normalize(r.text).contains($0) } }
                return routines.items.count == 1
            }
            guard let victim else { speak(replyLang == "en" ? "I don't find that routine." : "No encuentro esa rutina.", thenIdle: false); return }
            routines.remove(id: victim.id)
            let msg = replyLang == "en" ? "Removed the routine: \(victim.text)." : "Quité la rutina: \(victim.text)."
            logConv("< \(msg)")
            speak(msg, thenIdle: false); return
        }
        if let (when, text0, spoken) = parseReminder(n) {
            // Recupera acentos del texto original si las longitudes coinciden
            var text = text0
            let normCmd = normalize(cmd)
            if (normCmd as NSString).length == (cmd as NSString).length, let r = normCmd.range(of: text0) {
                text = String(cmd[r])
            }
            reminders.add(text: text, at: when)
            UsageStore.shared.countLocal()
            logConv("(recordatorio) \(text) -> \(when)")
            updateRemindersLine()
            speak(spoken, thenIdle: false); return
        }
        if let m = memoryRegex.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let fact = (cmd as NSString).length == (n as NSString).length
                ? (cmd as NSString).substring(with: m.range(at: 3)) : (n as NSString).substring(with: m.range(at: 3))
            let clean = fact.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            MemoryFile.append(clean)
            UsageStore.shared.countLocal()
            logConv("(memoria) - \(clean)")
            speak(replyLang == "en" ? "Got it, I'll keep that in mind." : "Listo, lo tendré en cuenta.", thenIdle: false); return
        }
        if sessionIsStale() {
            claude.stop()
            clearSession()
            logConv("--- nueva conversación (20 min sin actividad) ---")
        }
        // Permiso de pantalla: se comprueba antes de cambiar de estado
        let screenMode: ScreenMode = matches(regionRegex, n) && (matches(eyesRegex, n) || matches(screenRegex, n)) ? .region
            : matches(eyesRegex, n) ? .window : matches(screenRegex, n) ? .full : .none
        let wantsScreen = screenMode != .none
        if wantsScreen && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            logConv("< (sin permiso de Grabación de pantalla; pedido en Ajustes del Sistema)")
            speak(replyLang == "en" ? "To see your screen I need Screen Recording permission. Enable Claude Voice in System Settings, Privacy and Security, Screen Recording, then restart the app." : "Para ver tu pantalla necesito el permiso de Grabación de pantalla. Activa Claude Voice en Ajustes del Sistema, Privacidad y seguridad, Grabación de pantalla, y reinicia la app.", thenIdle: true)
            return
        }
        let wantsSelection = matches(selectionRegex, n)
        if wantsSelection && !accessibilityGranted(prompt: true) {
            speak(replyLang == "en" ? "I couldn't read the selection. Grant Accessibility access to Claude Voice in System Settings." : "No pude leer la selección. Dale permiso de Accesibilidad a Claude Voice en Ajustes del Sistema.", thenIdle: false); return
        }
        var cmdToSend = cmd
        if matches(clipboardRegex, n), let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
            cmdToSend += "\n\n[Contenido del portapapeles]\n" + String(clip.prefix(6000))
        }
        state = .thinking
        if sendSound { earcons.sent() }
        overlay.showPause(!silent)
        var (model, modelName) = chooseModel(for: cmd)
        // Las órdenes simples usan el modelo que ya está corriendo: reiniciar el proceso costaría más que la orden
        if claude.isRunning, model != claude.currentModel, !matches(deepRegex, normalize(cmd)) {
            let running = claude.currentModel
            let names = ["haiku": "Haiku", "sonnet": "Sonnet", "opus": "Opus"]
            model = running
            modelName = running.flatMap { names[$0] } ?? "Fable"
        }
        currentModelName = modelName
        overlay.set("Pensando · \(modelName)", cmd, .thinking)
        statusLine.title = "Pensando (\(modelName))"
        setIcon("ellipsis.circle.fill")
        let sendNow: (String) -> Void = { [weak self] text in
            guard let self, self.state == .thinking else { return }
            self.runClaude(text, model: model, retry: true)
            logConv("> [\(modelName)] \(cmd)")
        }
        if screenMode == .region {
            overlay.set("Marca la zona…", cmd, .thinking)
            speak(replyLang == "en" ? "Mark the area." : "Marca la zona.", thenIdle: false)
            state = .thinking
        }
        gatherContext(cmdToSend, screen: screenMode, selection: wantsSelection, completion: sendNow)
    }

    enum ScreenMode { case none, full, window, region }

    /// Ventana principal de la app activa (para "¿qué es esto?" sin capturar toda la pantalla).
    private func frontWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) < 80 || (b["Height"] ?? 0) < 80 { continue }
            return w[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    private var currentModelName = ""

    private func runClaude(_ cmd: String, model: String?, retry: Bool) {
        currentCmd = cmd.components(separatedBy: "\n\n[").first ?? cmd
        promoteWork?.cancel()
        if !typedReply {
            let w = DispatchWorkItem { [weak self] in self?.promoteToBackground() }
            promoteWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: w)
        }
        streamText = ""
        streamSpokenUpTo = 0
        processDone = false
        claude.send(cmd, model: model, onStatus: { [weak self] label in
            guard let self, self.state == .thinking || self.state == .speaking else { return }
            if self.state == .thinking { self.overlay.set("\(label) · \(self.currentModelName)", self.currentCmd, .thinking) }
            else { self.overlay.setTitle("\(label) · \(self.currentModelName)") }
            self.statusLine.title = "\(label) (\(self.currentModelName))"
        }, onText: { [weak self] delta in
            guard let self, self.state == .thinking || self.state == .speaking else { return }
            self.streamText += delta
            if self.state == .thinking { self.beginStreamingSpeech() }
            self.overlay.set("Claude · \(self.currentModelName)", self.streamText, .speaking)
            self.flushSentences(final: false)
        }, completion: { [weak self] reply, failed in
            guard let self, self.state == .thinking || self.state == .speaking else { return }
            self.promoteWork?.cancel(); self.promoteWork = nil
            if failed && retry && self.streamText.isEmpty && self.claude.lastFailureWasExit {
                // Solo si el proceso murió (p. ej. sesión que ya no existe): sesión nueva y reintento
                logApp("El proceso de Claude murió; reinicio con sesión nueva y reintento")
                self.claude.stop()
                clearSession()
                self.runClaude(cmd, model: model, retry: false); return
            }
            if failed && self.streamText.isEmpty {
                self.streamText = self.replyLang == "en" ? "Something went wrong, please try again." : "Hubo un error, inténtalo de nuevo."
            }
            touchSessionTime()
            if let shot = self.screenshotToDelete { try? FileManager.default.removeItem(at: shot); self.screenshotToDelete = nil }
            if self.streamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let text = (reply?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Hubo un error, revisa el log."
                self.streamText = text
                if self.state == .thinking { self.beginStreamingSpeech() }
                self.overlay.set("Claude · \(self.currentModelName)", self.streamText, .speaking)
            }
            self.processDone = true
            logConv("< \(self.streamText.replacingOccurrences(of: "\n", with: " "))")
            self.flushSentences(final: true)
            if !self.speaker.isSpeaking { self.finishSpeaking() }
        })
    }

    /// Pasa a estado "hablando" en cuanto llega la primera frase, sin esperar la respuesta completa.
    /// Une un segmento nuevo al anterior sin repetir las palabras del borde ("cuéntame algo" + "algo más" = "cuéntame algo más").
    private func joinWithoutOverlap(_ prefix: String, _ fresh: String) -> String {
        let a = prefix.split(separator: " ").map(String.init)
        var b = fresh.split(separator: " ").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return prefix + fresh }
        let norm: (String) -> String = { normalize($0).trimmingCharacters(in: .punctuationCharacters) }
        for k in stride(from: min(3, a.count, b.count), through: 1, by: -1) {
            if a.suffix(k).map(norm) == b.prefix(k).map(norm) { b.removeFirst(k); break }
        }
        return (a + b).joined(separator: " ")
    }

    /// Quita del inicio las palabras que son cola de la última respuesta de Claude (eco que llega con retraso).
    private func stripReplyEcho(_ text: String) -> String {
        guard segmentPrefix.isEmpty, !overlayLastReply.isEmpty else { return text }
        let norm: (String) -> String = { normalize($0).trimmingCharacters(in: .punctuationCharacters) }
        let replyWords = normalize(overlayLastReply).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, !replyWords.isEmpty else { return text }
        // Las k primeras palabras deben ser exactamente las k últimas de la respuesta, en orden
        for k in stride(from: min(6, words.count, replyWords.count), through: 1, by: -1) {
            if words.prefix(k).map(norm) == Array(replyWords.suffix(k)) {
                if k == 1 && words[0].count < 4 { break }   // una sola palabra corta no cuenta como eco
                return words.dropFirst(k).joined(separator: " ")
            }
        }
        return text
    }

    private func resetRecognizerText() { rawNow = ""; rawByLang = [:]; lastRawText = "" }

    private func beginStreamingSpeech() {
        listener.setEchoActive(true)
        resetRecognizerText()
        if Date().timeIntervalSince(listener.lastRestart) > 1.5 { listener.restart() }
        state = .speaking
        overlay.showPause(!silent)
        overlayLastReply = ""
        speakThenIdle = false
        if !silent { media.pauseIfPlaying() }
        speakStart = Date()
        speakBaseline = 0
        loudSince = nil
        statusLine.title = "Hablando"
        setIcon("speaker.wave.2.circle.fill")
        speaker.onRange = { [weak self] r in
            guard let self, self.state == .speaking else { return }
            self.overlay.highlight(r)
        }
        speaker.onFinish = { [weak self] in
            guard let self, self.state == .speaking else { return }
            if self.processDone && !self.speaker.isSpeaking { self.finishSpeaking() }
        }
    }

    /// Encola para hablar las frases completas que aún no se han dicho.
    private func flushSentences(final: Bool) {
        let ns = streamText as NSString
        guard streamSpokenUpTo < ns.length else { return }
        overlayLastReply = streamText
        let pending = ns.substring(from: streamSpokenUpTo)
        var cut = 0
        if !final {
            // último límite de frase (. ! ? o salto de línea seguido de espacio/fin)
            let ms = rx(#"[.!?…:\n](?=\s|$)"#).matches(in: pending, range: NSRange(location: 0, length: (pending as NSString).length))
            if let last = ms.last { cut = last.range.location + last.range.length }
            if cut < 12 { return }   // frases muy cortas: espera a que haya más texto
        } else {
            cut = (pending as NSString).length
        }
        let chunk = (pending as NSString).substring(to: cut)
        let clean = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty && !silent { speaker.speak(chunk, offset: streamSpokenUpTo) }
        streamSpokenUpTo += cut
        if !silent { armSpeakWatchdog() }
    }

    private func finishSpeaking() {
        guard state == .speaking else { return }
        speakWatchdog?.cancel()
        if silent {
            // Respuesta escrita: déjala en pantalla un rato proporcional a su largo y vuelve a reposo
            let words = streamText.split(separator: " ").count
            let delay = min(40, max(6, Double(words) / 2.5))
            overlayLastReply = streamText
            state = .idle
            typedReply = false
            listener.restart()
            setIcon("waveform.circle")
            statusLine.title = "Esperando \"hey claude\""
            overlay.set("Claude", streamText, .idle)
            overlay.hide(after: delay)
            return
        }
        enterListening(followUp: true)
    }

    private func speak(_ text: String, thenIdle: Bool) {
        listener.setEchoActive(true)
        resetRecognizerText()
        if silent {
            streamText = text
            state = .speaking
            processDone = true
            overlay.set("Claude", text, .speaking)
            overlay.show()
            finishSpeaking()
            return
        }
        state = .speaking
        processDone = true
        overlay.showPause(true)
        overlayLastReply = text
        speakThenIdle = thenIdle
        media.pauseIfPlaying()
        speakStart = Date()
        streamText = text
        armSpeakWatchdog()
        speakBaseline = 0
        loudSince = nil
        overlay.set("Claude", text, .speaking)
        overlay.show()
        statusLine.title = "Hablando"
        setIcon("speaker.wave.2.circle.fill")
        listener.restart()
        speaker.onRange = { [weak self] r in
            guard let self, self.state == .speaking else { return }
            self.overlay.highlight(r)
        }
        speaker.onFinish = { [weak self] in
            guard let self, self.state == .speaking, !self.speaker.isSpeaking else { return }
            if thenIdle { self.goIdle() } else { self.enterListening(followUp: true) }
        }
        speaker.speak(text)
    }

    /// Mientras Claude habla, mide el nivel del micrófono. Su propia voz por las bocinas marca una base;
    /// si el nivel sube muy por encima de esa base durante un rato, es el usuario hablando encima.
    private var lastForeignSpeechAt = Date.distantPast
    private func checkLoudInterrupt() {
        guard state == .speaking, !silent else { loudSince = nil; return }   // sin voz no hay nada que interrumpir por ruido
        let since = Date().timeIntervalSince(speakStart)
        if since < 1.2 { speakBaseline = max(speakBaseline, smoothLevel); return }
        let phones = listener.outputIsHeadphones
        let threshold = phones ? max(0.07, speakBaseline * 1.3) : max(0.16, speakBaseline * 1.5)
        // Volumen alto + palabras ajenas recientes = el usuario habla (corte rápido). Solo volumen (puerta, tos, música):
        // hace falta que dure bastante más, para no cortar por ruidos.
        let heardUser = Date().timeIntervalSince(lastForeignSpeechAt) < 2.0
        let needed: TimeInterval = heardUser ? (phones ? 0.3 : 0.45) : 1.5
        if smoothLevel > threshold {
            if loudSince == nil { loudSince = Date() }
            else if Date().timeIntervalSince(loudSince!) > needed {
                logApp(String(format: "Interrumpido por volumen: nivel %.2f, base %.2f", smoothLevel, speakBaseline))
                loudSince = nil
                interrupt()
            }
        } else {
            loudSince = nil
            speakBaseline = speakBaseline * 0.995 + smoothLevel * 0.005
        }
    }

    private func interrupt(seed: String = "") {
        speakWatchdog?.cancel()
        speaker.onFinish = nil
        speaker.stop()
        if !processDone { claude.interruptTurn(); processDone = true; logConv("< (interrumpido) \(streamText.replacingOccurrences(of: "\n", with: " "))") }
        enterListening(followUp: true)
        let seedClean = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seedClean.isEmpty {
            segmentPrefix = seedClean + " "
            commandText = seedClean
            lastChange = Date()
            overlay.set("Escuchando…", commandText, .listening)
        }
    }

    private func goIdle(immediate: Bool = false) {
        listener.setEchoActive(false)
        overlay.showPause(false)
        speakWatchdog?.cancel()
        rawNow = ""
        rawByLang = [:]
        if let (when, next) = announceQueue.first {
            announceQueue.removeAll()
            if Date().timeIntervalSince(when) < 20 {
                state = .idle
                overlay.show()
                speak(next, thenIdle: true)
                return
            }
        }
        state = .idle
        typedReply = false
        followUp = false
        commandText = ""
        listener.restart()
        media.resumeIfPaused()
        setIcon("waveform.circle")
        overlay.set("Claude", overlayLastReply, .idle)
        if immediate { overlay.hide() } else { overlay.hide(after: overlayLastReply.isEmpty ? 0.5 : 5) }
        statusLine.title = "Esperando \"hey claude\""
    }

    private func fireReminder(_ r: Reminder) {
        updateRemindersLine()
        let content = UNMutableNotificationContent()
        content.title = "Claude"
        content.body = r.text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil))
        earcons.reminder()
        logConv("(recordatorio disparado) \(r.text)")
        typedReply = false
        media.pauseIfPlaying()
        overlay.show()
        let en = textLanguage(r.text) == "en" || r.text == "Time's up"
        speak(r.text == "Se acabó el tiempo" ? "Se acabó el tiempo." : r.text == "Time's up" ? "Time's up." : (en ? "Reminder: \(r.text)." : "Recordatorio: \(r.text)."), thenIdle: true)
    }

    private func updateRemindersLine() {
        let n = reminders.items.count
        remindersLine.title = n == 0 ? "Sin recordatorios pendientes" : (n == 1 ? "1 recordatorio pendiente" : "\(n) recordatorios pendientes")
    }

    /// Orden escrita con ⌥⌘T: se procesa igual pero la respuesta solo se muestra, no se habla.
    /// Una vez por semana, en reposo y en horario razonable, cuenta lo nuevo que aprendió de ti.
    private var memorySummaryChecked = Date.distantPast
    private func weeklyMemorySummaryIfDue() {
        guard Date().timeIntervalSince(memorySummaryChecked) > 600 else { return }
        memorySummaryChecked = Date()
        let hour = Calendar.current.component(.hour, from: Date())
        guard (9...21).contains(hour), tasks.running.isEmpty else { return }
        let last = UserDefaults.standard.object(forKey: "memorySummaryAt") as? Date ?? Date.distantPast
        guard Date().timeIntervalSince(last) > 7 * 86400 else { return }
        let fresh = MemoryFile.newSince(days: 7)
        UserDefaults.standard.set(Date(), forKey: "memorySummaryAt")
        guard !fresh.isEmpty else { return }
        let msg = "Esta semana aprendí \(fresh.count) \(fresh.count == 1 ? "cosa" : "cosas") de ti: \(fresh.prefix(3).joined(separator: "; ")). Si algo no es así, dímelo o bórralo en Ajustes, Memoria."
        logConv("(memoria semanal) \(msg)")
        announce(msg)
    }

    /// Ejecuta una rutina programada como si la hubieras dicho: la respuesta se lee en voz alta.
    private func fireRoutine(_ r: Routine) {
        logConv("> (rutina \(r.whenText)) \(r.text)")
        listener.stop()
        state = .listening
        typedReply = false
        commandText = ""
        overlay.set("Rutina", r.text, .listening)
        overlay.show()
        media.pauseIfPlaying()
        commit(r.text)
    }

    func typedCommand(_ text: String) {
        if state == .speaking { interrupt() }
        if state == .thinking { claude.cancel(); processDone = true }
        listener.stop()
        state = .listening
        typedReply = true
        commandText = ""
        overlay.set("Escribiste", text, .listening)
        overlay.show()
        commit(text)
    }

    @objc func testVoice() { testVoice(english: false) }
    func testVoice(english: Bool) {
        guard state == .idle else { return }
        typedReply = false
        overlay.show()
        speak(english ? "Hi, I'm Claude. This is how I sound in English." : "Hola, soy Claude. Así sueno con esta voz.", thenIdle: true)
    }

    @objc func openVoiceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() { settingsWindow.show() }
    func refreshIdleIndicator() { if state == .idle { overlay.hide() } }

    @objc func openInput() { input.open() }
    @objc func toggleTheme(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!overlay.isLight, forKey: "lightTheme")
        sender.state = overlay.isLight ? .on : .off
        overlay.applyTheme()
    }
    @objc func toggleIndicator(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!overlay.showsIndicator, forKey: "idleIndicator")
        sender.state = overlay.showsIndicator ? .on : .off
        if state == .idle { overlay.hide() }
    }

    /// Captura de pantalla (en segundo plano) y selección (asíncrona) antes de enviar la orden.
    private func gatherContext(_ cmd: String, screen: ScreenMode, selection: Bool, completion: @escaping (String) -> Void) {
        var text = cmd
        let afterScreen: () -> Void = { [weak self] in
            guard let self else { return }
            if selection {
                self.copySelectionFromFrontApp { sel in
                    if let sel, !sel.isEmpty { text += "\n\n[Texto seleccionado]\n" + String(sel.prefix(6000)) }
                    completion(text)
                }
            } else {
                completion(text)
            }
        }
        guard screen != .none else { afterScreen(); return }
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("hey-claude-pantalla-\(UUID().uuidString.prefix(8)).jpg")
        let target = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let rect: String? = target.map { f in
            "\(Int(f.frame.minX)),\(Int(NSScreen.screens[0].frame.maxY - f.frame.maxY)),\(Int(f.frame.width)),\(Int(f.frame.height))"
        }
        let windowID = screen == .window ? frontWindowID() : nil
        let what = screen == .region ? "la zona que marqué" : windowID != nil ? "la ventana activa" : "mi pantalla"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["-x", "-t", "jpg"]
            if screen == .region { args.append("-i") }                 // el usuario arrastra para elegir la zona (Esc cancela)
            else if let windowID { args += ["-o", "-l", "\(windowID)"] }   // solo la ventana activa, sin sombra
            else if let rect { args += ["-R", rect] }
            args.append(shot.path)
            _ = shell("/usr/sbin/screencapture", args)
            DispatchQueue.main.async {
                guard let self else { return }
                if FileManager.default.fileExists(atPath: shot.path) {
                    text += "\n\n[Adjunto una captura de \(what) en \(shot.path). Léela con la herramienta Read antes de responder; responde sobre lo que se ve.]"
                    logApp("Captura adjuntada (\(what))")
                    self.screenshotToDelete = shot
                }
                afterScreen()
            }
        }
    }

    private func accessibilityGranted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Envía ⌘C a la app activa y entrega lo seleccionado sin bloquear ni perder el portapapeles.
    private func copySelectionFromFrontApp(completion: @escaping (String?) -> Void) {
        guard accessibilityGranted(prompt: true) else { completion(nil); return }
        let pb = NSPasteboard.general
        let before = snapshotPasteboard()
        let changeCount = pb.changeCount
        postKey(keyCode: 8, flags: .maskCommand)   // ⌘C
        var tries = 0
        func poll() {
            tries += 1
            if pb.changeCount != changeCount {
                let sel = pb.string(forType: .string)
                self.restorePasteboard(before)
                completion(sel)
            } else if tries < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            } else {
                completion(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }

    /// Copia completa del portapapeles (todos los tipos), para restaurarla después.
    private func snapshotPasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }
    private func restorePasteboard(_ snap: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = snap.map { dict in
            let it = NSPasteboardItem()
            for (t, data) in dict { it.setData(data, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    /// Escribe texto en la app activa pegándolo (⌘V) sin perder el portapapeles anterior.
    private func typeIntoFrontApp(_ text: String) -> Bool {
        guard accessibilityGranted(prompt: true) else { return false }
        let pb = NSPasteboard.general
        let before = snapshotPasteboard()
        pb.clearContents(); pb.setString(text, forType: .string)
        postKey(keyCode: 9, flags: .maskCommand)   // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restorePasteboard(before) }
        return true
    }

    /// Respuestas que no necesitan modelo: hora, fecha, batería, recordatorios pendientes.
    /// Control del Mac sin modelo: brillo, volumen, bloqueo, dormir, apps, música, auriculares, discos, no molestar.
    private func macControl(_ n: String, original: String) -> String? {
        let en = replyLang == "en"
        func osa(_ src: String) -> String { shell("/usr/bin/osascript", ["-e", src]).trimmingCharacters(in: .whitespacesAndNewlines) }
        func keyTimes(_ code: Int, _ times: Int) { _ = osa("tell application \"System Events\" to repeat \(times) times\nkey code \(code)\nend repeat") }
        func num(_ s: String) -> Int? { rx(#"(\d+)"#).firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)).flatMap { Int((s as NSString).substring(with: $0.range(at: 1))) } }
        // Brillo
        if matches(rx(#"^(sube|aumenta|mas) (el )?brillo|^brillo (al maximo|mas alto|arriba)|^(brightness up|increase brightness|max brightness)"#), n) {
            keyTimes(144, n.contains("maximo") || n.contains("max") ? 16 : 3); return en ? "Brighter." : "Más brillo."
        }
        if matches(rx(#"^(baja|reduce|menos) (el )?brillo|^brillo (al minimo|mas bajo|abajo)|^(brightness down|decrease brightness|min brightness)"#), n) {
            keyTimes(145, n.contains("minimo") || n.contains("min") ? 16 : 3); return en ? "Dimmer." : "Menos brillo."
        }
        // Volumen del sistema
        if let m = rx(#"^(pon (el )?volumen|volumen) (al|a|en) (\d+)"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let v = min(100, Int((n as NSString).substring(with: m.range(at: 4))) ?? 50)
            _ = osa("set volume output volume \(v)"); return en ? "Volume at \(v)." : "Volumen al \(v)."
        }
        if matches(rx(#"^(sube|aumenta|mas) (el )?volumen|^(volume up|louder|turn it up)"#), n) {
            let cur = Int(osa("output volume of (get volume settings)")) ?? 50
            _ = osa("set volume output volume \(min(100, cur + 15))"); return en ? "Louder." : "Más alto."
        }
        if matches(rx(#"^(baja|reduce|menos) (el )?volumen|^(volume down|quieter|turn it down)"#), n) {
            let cur = Int(osa("output volume of (get volume settings)")) ?? 50
            _ = osa("set volume output volume \(max(0, cur - 15))"); return en ? "Quieter." : "Más bajo."
        }
        if matches(rx(#"^(silencia|mutea|quita el sonido (de|a)) (la|el|mi) (mac|computadora|compu|bocinas|altavoces|sonido)|^(mute the mac|mute the computer|mute the speakers)"#), n) {
            _ = osa("set volume with output muted"); return en ? "Muted." : "Silenciado."
        }
        if matches(rx(#"^(activa|pon|devuelve|regresa) el sonido( de la mac)?|^(quita el silencio|unmute the mac|unmute the computer|sound on)"#), n) {
            _ = osa("set volume without output muted"); return en ? "Sound is back." : "Sonido activado."
        }
        // Pantalla y energía
        if matches(rx(#"^(bloquea|bloquear|cierra sesion de|lock) (la )?(pantalla|mac|computadora|screen|computer)"#), n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = osa("tell application \"System Events\" to keystroke \"q\" using {command down, control down}") }   // ⌃⌘Q
            return en ? "Locking." : "Bloqueo la pantalla."
        }
        if matches(rx(#"^(apaga|apagar) (la )?pantalla|^(screen off|turn off the screen|turn off the display)"#), n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = shell("/usr/bin/pmset", ["displaysleepnow"]) }
            return en ? "Screen off." : "Apago la pantalla."
        }
        if matches(rx(#"^(pon a dormir|duerme|suspende) (la |el )?(mac|computadora|compu)|^(go to sleep|sleep the mac|put the mac to sleep)"#), n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = osa("tell application \"System Events\" to sleep") }
            return en ? "Good night." : "Buenas noches."
        }
        // Apps: cerrar una, o todas menos algunas
        if let m = rx(#"^(cierra|cerrar|quita|quit|close) (todas las apps|todas las aplicaciones|todo|all apps|everything)(?: (menos|excepto|salvo|except|but) (.+))?$"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let keep = m.range(at: 4).location != NSNotFound ? (n as NSString).substring(with: m.range(at: 4)).split(whereSeparator: { $0 == "," || $0 == " " }).map { normalize(String($0)) }.filter { !["y", "and", "el", "la", "de"].contains($0) } : []
            var closed: [String] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != NSRunningApplication.current {
                let name = app.localizedName ?? ""
                let nn = normalize(name)
                if nn == "finder" || keep.contains(where: { !$0.isEmpty && (nn.contains($0) || $0.contains(nn)) }) { continue }
                if app.terminate() { closed.append(name) }
            }
            if closed.isEmpty { return en ? "Nothing to close." : "No había nada que cerrar." }
            return en ? "Closed \(closed.count): \(closed.prefix(5).joined(separator: ", "))." : "Cerré \(closed.count): \(closed.prefix(5).joined(separator: ", "))."
        }
        if let m = rx(#"^(cierra|cerrar|quit|close) (la app |la aplicacion |the app )?(.+)$"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            var target = normalize((n as NSString).substring(with: m.range(at: 3))).trimmingCharacters(in: .punctuationCharacters)
            target = target.replacingOccurrences(of: #"^(la|el|los|las|the|a|un|una)\s+"#, with: "", options: .regularExpression)
            let aliases = ["calculadora": "calculator", "musica": "music", "notas": "notes", "mensajes": "messages", "correo": "mail", "fotos": "photos", "terminal": "terminal", "ajustes": "system settings", "calendario": "calendar", "recordatorios": "reminders", "vista previa": "preview", "navegador": "chrome"]
            let wanted = aliases[target] ?? target
            if let app = NSWorkspace.shared.runningApplications.first(where: { a in
                guard a.activationPolicy == .regular, let ln = a.localizedName else { return false }
                let nn = normalize(ln); return nn == wanted || nn.contains(wanted) || wanted.contains(nn) || nn == target
            }), app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.terminate(); return en ? "Closed \(app.localizedName ?? "it")." : "Cerré \(app.localizedName ?? "la app")."
            }
            return nil   // no es una app abierta: que lo interprete el modelo
        }
        // Música (Music o Spotify, la que esté corriendo)
        if matches(rx(#"^(pausa|pausar|para|detén|deten) (la )?(musica|cancion|reproduccion)|^(pause the music|pause music|pause the song)"#), n) {
            for app in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) { _ = osa("tell application \"\(app)\" to pause") }
            return en ? "Paused." : "Pausado."
        }
        if matches(rx(#"^(reanuda|continua|sigue|pon|reproduce) (la )?(musica|cancion|reproduccion)|^(play the music|resume the music|play music|resume music)"#), n) {
            for app in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) { _ = osa("tell application \"\(app)\" to play") }
            return en ? "Playing." : "Sigue la música."
        }
        if matches(rx(#"^(siguiente|proxima|otra) (cancion|pista)|^(next song|next track|skip this song|skip)$"#), n) {
            for app in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) { _ = osa("tell application \"\(app)\" to next track") }
            return en ? "Next." : "Siguiente."
        }
        if matches(rx(#"^(anterior|la de antes|regresa la) (cancion|pista)|^(previous song|previous track|go back a song)"#), n) {
            for app in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) { _ = osa("tell application \"\(app)\" to previous track") }
            return en ? "Previous." : "Anterior."
        }
        // Auriculares Bluetooth (requiere blueutil: brew install blueutil)
        if let m = rx(#"^(conecta|conectar|desconecta|desconectar|connect|disconnect) (los |mis |the |my )?(airpods|audifonos|auriculares|headphones|earbuds|bocina|altavoz|speaker)( .*)?$"#).firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let connect = n.hasPrefix("conecta") || n.hasPrefix("connect")
            let bu = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let bu else { return en ? "To connect Bluetooth devices I need blueutil: brew install blueutil." : "Para conectar dispositivos Bluetooth necesito blueutil: brew install blueutil." }
            let kind = (n as NSString).substring(with: m.range(at: 3))
            let paired = shell(bu, ["--paired", "--format", "json"])
            guard let data = paired.data(using: .utf8), let devs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return en ? "I couldn't list your Bluetooth devices." : "No pude leer tus dispositivos Bluetooth." }
            let wantPods = ["airpods", "audifonos", "auriculares", "headphones", "earbuds"].contains(kind)
            let dev = devs.first { d in
                let name = normalize(d["name"] as? String ?? "")
                return wantPods ? (name.contains("airpods") || name.contains("pods") || name.contains("buds") || name.contains("headphone") || name.contains("wh-") || name.contains("beats")) : (name.contains("speaker") || name.contains("bocina") || name.contains("jbl") || name.contains("bose"))
            }
            guard let dev, let addr = dev["address"] as? String else { return en ? "I don't see paired headphones." : "No veo audífonos emparejados." }
            _ = shell(bu, [connect ? "--connect" : "--disconnect", addr])
            let name = dev["name"] as? String ?? "el dispositivo"
            return connect ? (en ? "Connecting \(name)." : "Conectando \(name).") : (en ? "Disconnected \(name)." : "Desconecté \(name).")
        }
        // Discos externos
        if matches(rx(#"^(expulsa|expulsar|desmonta|eject) (los |todos los |the )?(discos|disco|unidades|usb|drives|disks)"#), n) {
            _ = osa("tell application \"Finder\" to eject (every disk whose ejectable is true)")
            return en ? "Ejected." : "Discos expulsados."
        }
        // No molestar / concentración: usa un Atajo llamado "No molestar" (acción "Establecer modo de concentración")
        if matches(rx(#"^(activa|pon|enciende|quita|desactiva|apaga) (el )?(modo )?(no molestar|concentracion|enfoque|focus)|^(do not disturb|focus mode) (on|off)|^(turn (on|off) (do not disturb|focus))"#), n) {
            let off = matches(rx(#"\b(quita|desactiva|apaga|off)\b"#), n)
            let list = shell("/usr/bin/shortcuts", ["list"])
            let name = list.split(separator: "\n").map(String.init).first { normalize($0).contains("no molestar") || normalize($0).contains("concentracion") || normalize($0).contains("focus") }
            guard let name else { return en ? "Create a Shortcut named \"No molestar\" with the action Set Focus, and I'll run it." : "Crea un Atajo llamado \"No molestar\" con la acción Establecer modo de concentración, y lo ejecuto por ti." }
            _ = shell("/usr/bin/shortcuts", ["run", name, "-i", off ? "off" : "on"])
            return off ? (en ? "Focus off." : "Modo concentración desactivado.") : (en ? "Focus on." : "Modo concentración activado.")
        }
        return nil
    }

    /// Busca en voice.log lo que se habló sobre un tema, acotado por "hoy", "ayer", "la semana pasada"...
    private func searchHistory(topic: String, query: String) -> String {
        let en = replyLang == "en"
        guard let log = try? String(contentsOf: logFile, encoding: .utf8) else { return en ? "I have no history yet." : "Todavía no tengo historial." }
        let cal = Calendar.current
        var from = cal.date(byAdding: .day, value: -30, to: Date())!, to = Date()
        var when = en ? "recently" : "últimamente"
        if matches(rx(#"\b(hoy|today)\b"#), query) { from = cal.startOfDay(for: Date()); when = en ? "today" : "hoy" }
        else if matches(rx(#"\b(ayer|yesterday)\b"#), query) { from = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!); to = cal.startOfDay(for: Date()); when = en ? "yesterday" : "ayer" }
        else if matches(rx(#"\b(antier|anteayer)\b"#), query) { from = cal.startOfDay(for: cal.date(byAdding: .day, value: -2, to: Date())!); to = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: Date())!); when = "antier" }
        else if matches(rx(#"\b(esta semana|this week)\b"#), query) { from = cal.date(byAdding: .day, value: -7, to: Date())!; when = en ? "this week" : "esta semana" }
        else if matches(rx(#"\b(la semana pasada|last week)\b"#), query) { from = cal.date(byAdding: .day, value: -14, to: Date())!; to = cal.date(byAdding: .day, value: -7, to: Date())!; when = en ? "last week" : "la semana pasada" }
        let words = normalize(topic).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !["los", "las", "del", "que", "the", "con", "por", "para", "una", "uno"].contains($0) }
        guard !words.isEmpty else { return en ? "About what?" : "¿Sobre qué?" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lastOrder = ""; var best: (Date, String, String, Int)? = nil
        for raw in log.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("["), (line as NSString).length > 21, let d = f.date(from: String(line.dropFirst().prefix(19))) else { continue }
            let body = String(line.dropFirst(22))
            if body.hasPrefix("> ") { lastOrder = body; continue }
            guard d >= from, d <= to, body.hasPrefix("< ") else { continue }
            let hay = normalize(body + " " + lastOrder)
            let score = words.filter { hay.contains($0) }.count
            if score > 0, best == nil || score >= best!.3 { best = (d, lastOrder, body, score) }
        }
        guard let (d, order, reply, _) = best else {
            return en ? "I don't find anything about \(topic) \(when)." : "No encuentro nada sobre \(topic) \(when)."
        }
        let tf = DateFormatter(); tf.locale = Locale(identifier: en ? "en_US" : "es_MX")
        tf.dateFormat = cal.isDateInToday(d) ? "h:mm a" : cal.isDateInYesterday(d) ? (en ? "'yesterday at' h:mm a" : "'ayer a las' h:mm a") : (en ? "EEEE 'at' h:mm a" : "'el' EEEE 'a las' h:mm a")
        let cleanReply = reply.dropFirst(2).replacingOccurrences(of: #"^\((local|tarea|plan|segundo plano)\)\s*"#, with: "", options: .regularExpression)
        let cleanOrder = order.dropFirst(2).replacingOccurrences(of: #"^\[[^\]]*\]\s*|^\([^)]*\)\s*"#, with: "", options: .regularExpression)
        let excerpt = String(cleanReply.prefix(320))
        return en ? "\(tf.string(from: d)) you asked \"\(cleanOrder.prefix(80))\" and I said: \(excerpt)" : "\(tf.string(from: d)) preguntaste \"\(cleanOrder.prefix(80))\" y te dije: \(excerpt)"
    }

    private func instantAnswer(_ n: String) -> String? {
        let en = replyLang == "en"
        let loc = Locale(identifier: en ? "en_US" : "es_MX")
        func fmt(_ pattern: String) -> String { let f = DateFormatter(); f.locale = loc; f.dateFormat = pattern; return f.string(from: Date()) }
        if matches(rx(#"^(que hora es|dime la hora|que horas son|what time is it|what's the time|tell me the time)\b"#), n) {
            return en ? "It's \(fmt("h:mm a"))." : "Son las \(fmt("h:mm"))."
        }
        if matches(rx(#"^(que dia es|que fecha es|en que fecha estamos|que dia es hoy|what day is it|what's the date|what is the date|what's today's date)\b"#), n) {
            return en ? "Today is \(fmt("EEEE, MMMM d"))." : "Hoy es \(fmt("EEEE d 'de' MMMM"))."
        }
        if matches(rx(#"^(cuanta bateria|como esta la bateria|nivel de bateria|bateria|how much battery|battery level|battery)\b"#), n) {
            let out = shell("/usr/bin/pmset", ["-g", "batt"])
            if let m = try? NSRegularExpression(pattern: #"(\d+)%; (\w+)"#).firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
                let pct = (out as NSString).substring(with: m.range(at: 1)), st = (out as NSString).substring(with: m.range(at: 2))
                let charging = st == "charging" || st == "charged"
                return en ? "Battery is at \(pct) percent\(charging ? ", charging" : "")." : "La batería está al \(pct) por ciento\(charging ? ", cargando" : "")."
            }
        }
        if matches(rx(#"^(que tengo pendiente|que recordatorios tengo|mis recordatorios|recordatorios pendientes|what reminders do i have|my reminders|what's pending)\b"#), n) {
            let items = reminders.items.sorted { $0.fire < $1.fire }
            if items.isEmpty { return en ? "You have no pending reminders." : "No tienes recordatorios pendientes." }
            let f = DateFormatter(); f.locale = loc; f.dateFormat = "h:mm"
            let list = items.prefix(4).map { "\($0.text) \(en ? "at" : "a las") \(f.string(from: Date(timeIntervalSince1970: $0.fire)))" }.joined(separator: en ? ", and " : ", y ")
            return en ? "You have \(items.count): \(list)." : "Tienes \(items.count): \(list)."
        }
        return nil
    }

    // MARK: Tareas largas

    private func taskTimeout(from n: String) -> TimeInterval {
        if let m = taskTimeoutRegex.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)),
           let num = parseNumber((n as NSString).substring(with: m.range(at: 2))) {
            let unit = (n as NSString).substring(with: m.range(at: 3))
            return unit.hasPrefix("hora") || unit.hasPrefix("hour") ? Double(num) * 3600 : Double(num) * 60
        }
        return 30 * 60
    }

    /// Tarea en curso a la que se refiere la orden (por palabras de dirección o del título), si la hay.
    private func taskAddressed(by n: String) -> LongTask? {
        let running = tasks.running.filter { $0.status == .running }
        guard let t = running.first, !matches(explicitNewTaskRegex, n) else { return nil }
        if matches(steerRegex, n) { return t }
        let titleWords = Set(normalize(t.title).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 4 })
        let overlap = n.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { titleWords.contains($0) }
        return overlap.isEmpty ? nil : t
    }

    /// Interrumpe la tarea, le pasa tu instrucción y la hace continuar con toda su memoria.
    private func steerTask(_ t: LongTask, with instruction: String) {
        guard let proc = t.process else { return }
        logConv("> [a la tarea] \(instruction)")
        t.milestones.append(replyLang == "en" ? "You said: \(instruction)" : "Le dijiste: \(instruction)")
        let msg = "Instrucción del usuario mientras haces la tarea: \"\(instruction)\". Aplícala y continúa la tarea desde donde estaba. Si cambia el plan, escribe primero el PLAN actualizado con pasos numerados. Recuerda el protocolo PASO / HITO / RESULTADO: marca cada paso al empezarlo."
        if !proc.steer(msg) {
            // La tarea no estaba en medio de un turno: nueva orden en el mismo proceso vivo (sin reiniciar)
            proc.send(msg, model: proc.currentModel,
                      onStatus: taskStatusHandler(t), onText: taskTextHandler(t), completion: taskCompletionHandler(t))
        }
        tasks.onChange?()
        speak(replyLang == "en" ? "Got it, I passed that on." : "Listo, se lo paso.", thenIdle: true)
    }

    private func taskStatusHandler(_ t: LongTask) -> (String) -> Void {
        { [weak self] l in
            t.lastToolLabel = l; t.toolCalls += 1; t.lastActivity = Date(); self?.tasks.onChange?()
            if t.toolCalls > TaskManager.maxToolCalls { self?.tasks.finish(t, status: .failed, message: "Detuve la tarea \(t.title): demasiados pasos.") }
        }
    }
    private func taskTextHandler(_ t: LongTask) -> (String) -> Void {
        { [weak self] d in
            t.lastActivity = Date()
            for line in t.ingest(d) { logConv("(hito) \(line)"); self?.announce(line) }
            self?.tasks.onChange?()
        }
    }
    private func taskCompletionHandler(_ t: LongTask) -> (String?, Bool) -> Void {
        { [weak self] reply, failed in
            guard let self else { return }
            for line in t.flush() { self.announce(line) }
            guard t.status == .running else { return }
            let final = t.result ?? (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            t.result = final
            logConv("< (tarea) \(final.prefix(300))")
            if failed { self.tasks.finish(t, status: .failed, message: "La tarea \(t.title) falló. \(final.prefix(200))") }
            else { self.tasks.finish(t, status: .done, message: t.milestones.isEmpty && t.steps.isEmpty ? "Terminé: \(final.prefix(240))" : "Terminé la tarea. \(final.prefix(240))") }
        }
    }

    /// Pide el plan a un proceso propio y espera tu confirmación por voz.
    private func planTask(_ cmd: String, n: String) {
        panelDismissed = false
        let t = LongTask(title: cmd, timeout: taskTimeout(from: n))
        let fast = matches(rx(#"\b(rapido|rapida|apurate|date prisa|faster|hurry|quick|quickly)\b"#), n)
        let proc = PersistentClaude(tools: allowedTools + "," + taskExtraTools, extraPrompt: taskPrompt, ownSession: true, effort: fast ? "low" : taskEffort)
        t.process = proc
        tasks.add(t)
        state = .thinking
        overlay.showPause(true)
        overlay.set("Planificando · tarea", cmd, .thinking)
        statusLine.title = "Planificando tarea"
        setIcon("ellipsis.circle.fill")
        logConv("> [tarea] \(cmd)")
        streamText = ""; streamSpokenUpTo = 0; processDone = false
        var planText = ""
        let tiers = loadModelTiers()
        let normal = tiers["normal"] ?? "sonnet"
        let history = recentTaskHistory()
        let historyBlock = history.isEmpty ? "" : "Tareas anteriores recientes, por si esta orden se refiere a alguna (\"vuelve a\", \"otra vez\", \"la misma\"...). El dictado deforma nombres propios: si un nombre de la orden se parece a uno de aquí, es ese.\n\(history)\n\n"
        proc.send("Tarea: \(cmd)\n\n" + historyBlock + "Escribe solo el PLAN (una línea \"PLAN: ...\" y los pasos numerados). No ejecutes nada todavía.", model: normal == "default" ? nil : normal,
                  onStatus: { [weak self] l in t.lastToolLabel = l; self?.tasks.onChange?() },
                  onText: { [weak self] d in
                      planText += d
                      _ = t.ingest(d)
                      self?.tasks.onChange?()
                  },
                  completion: { [weak self] reply, failed in
                      guard let self else { return }
                      _ = t.flush()
                      if failed { self.tasks.finish(t, status: .failed, message: nil); self.processDone = true; self.speak("No pude planificar la tarea.", thenIdle: true); return }
                      t.status = .waiting
                      self.pendingTask = t
                      self.tasks.onChange?()
                      let summary = t.planSummary.isEmpty ? (reply ?? "").prefix(300).description : t.planSummary
                      logConv("< (plan) \(summary)")
                      self.processDone = true
                      let ask = self.replyLang == "en" ? " Shall I go ahead?" : " ¿Arranco?"
                      self.speak(summary + ask, thenIdle: false)
                  })
        if showTasksPanel { refreshTasksPanel() }
    }

    /// Ejecuta la tarea en su proceso propio y devuelve el control.
    private func startTask(_ t: LongTask, extra: String? = nil) {
        guard let proc = t.process else { return }
        if let extra, matches(rx(#"\b(rapido|rapida|apurate|date prisa|faster|hurry|quick|quickly)\b"#), normalize(extra)) { proc.effort = "low" }
        if let extra { t.milestones.append(replyLang == "en" ? "You said: \(extra)" : "Le dijiste: \(extra)"); logConv("> [al plan] \(extra)") }
        t.status = .running
        t.runStartedAt = Date()
        t.deadline = Date().addingTimeInterval(t.deadline.timeIntervalSince(t.startedAt))
        tasks.onChange?()
        logConv("> [tarea en curso] \(t.title)")
        let go = "Adelante, ejecuta el plan." + (extra.map { " Indicación adicional del usuario: \"\($0)\". Si cambia el plan, escribe primero el PLAN actualizado (línea PLAN: y pasos numerados) y luego ejecuta." } ?? "") + " Recuerda el protocolo PASO / HITO / RESULTADO: marca cada paso al empezarlo."
        proc.send(go, model: proc.currentModel,
                  onStatus: taskStatusHandler(t), onText: taskTextHandler(t), completion: taskCompletionHandler(t))
        speak(replyLang == "en" ? "On it. I'll let you know." : "Voy con ello. Te aviso cuando termine.", thenIdle: true)
        if showTasksPanel { refreshTasksPanel() }
    }

    /// Una orden normal que se alarga pasa a segundo plano y libera el asistente.
    private func promoteToBackground() {
        guard state == .thinking, !processDone, !typedReply else { return }
        panelDismissed = false
        let t = LongTask(title: currentCmd, timeout: 30 * 60)
        t.status = .running
        t.runStartedAt = Date()
        t.lastToolLabel = overlayLastReply.isEmpty ? "" : ""
        t.process = claude
        // El proceso actual se queda con la tarea; la conversación sigue en uno nuevo (sesión nueva)
        let taskProc = claude
        claude = PersistentClaude()
        clearSession()
        logConv("--- la orden pasó a segundo plano; nueva conversación ---")
        tasks.add(t)
        taskProc.rebind(onStatus: { [weak self] l in t.lastToolLabel = l; t.toolCalls += 1; self?.tasks.onChange?() },
                        onText: { [weak self] d in for line in t.ingest(d) { self?.announce(line) } },
                        completion: { [weak self] reply, failed in
                            guard let self else { return }
                            for line in t.flush() { self.announce(line) }
                            guard t.status == .running else { return }
                            let final = (reply ?? t.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            t.result = final
                            logConv("< (segundo plano) \(final.prefix(300))")
                            self.tasks.finish(t, status: failed ? .failed : .done, message: (failed ? "La tarea falló. " : "Terminé: ") + final.prefix(240))
                            taskProc.stop()
                        })
        processDone = true
        streamText = ""
        speaker.stop()
        speak(replyLang == "en" ? "This is taking a while. I'll keep working in the background and let you know." : "Esto va para largo. Sigo en segundo plano y te aviso cuando termine.", thenIdle: true)
        let tiers = loadModelTiers(); let normal = tiers["normal"] ?? "sonnet"
        claude.prewarm(model: normal == "default" ? nil : normal)
        if showTasksPanel { refreshTasksPanel() }
    }

    /// Dice algo cuando el asistente está libre; si no, lo guarda para después.
    func announce(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if state == .idle {
            overlay.show()
            speak(clean, thenIdle: true)
        } else {
            // Solo se guarda el aviso más reciente: los hitos viejos ya no describen la situación actual
            announceQueue = [(Date(), clean)]
        }
    }

    /// Anillo y burbuja del widget según la tarea en curso (o el plan que espera tu confirmación).
    func updateWidgetTaskState() {
        let running = tasks.running.filter { $0.status == .running }
        if let d = pendingTask, d.status == .waiting {
            overlay.logo.attention = true; overlay.logo.taskBusy = false; overlay.logo.taskProgress = nil
            overlay.logo.toolTip = "Esperando tu confirmación: \(d.title)"
        } else if let t = running.first {
            overlay.logo.attention = false
            let done = t.steps.filter { $0.state == .done }.count
            let current = t.steps.contains { $0.state == .current } ? 0.5 : 0
            overlay.logo.taskProgress = t.steps.isEmpty ? nil : (Double(done) + current) / Double(t.steps.count)
            overlay.logo.taskBusy = t.steps.isEmpty
            let step = t.steps.isEmpty ? "" : " · paso \(min(t.steps.count, done + 1)) de \(t.steps.count)"
            overlay.logo.toolTip = "\(t.title)\(step)\n\(t.lastMilestone.isEmpty ? t.elapsedText : t.lastMilestone)"
        } else {
            overlay.logo.attention = false; overlay.logo.taskBusy = false; overlay.logo.taskProgress = nil
            overlay.logo.toolTip = nil
        }
    }

    /// Cada 3 s, mientras hay una tarea y el panel está a la vista, captura la ventana de Chrome para el panel.
    private var thumbTimer: Timer?
    private var thumbBusy = false
    private func updateThumbnailTimer() {
        let want = tasks.running.contains { $0.status == .running } && showTasksPanel && !panelDismissed && CGPreflightScreenCaptureAccess()
        if want, thumbTimer == nil {
            thumbTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.captureChromeThumbnail() }
            RunLoop.main.add(thumbTimer!, forMode: .common)
            captureChromeThumbnail()
        } else if !want, let t = thumbTimer {
            t.invalidate(); thumbTimer = nil
            tasksPanel.thumbnail = nil
        }
    }
    private func captureChromeThumbnail() {
        guard !thumbBusy else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        func area(_ w: [String: Any]) -> CGFloat {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return (b["Width"] ?? 0) * (b["Height"] ?? 0)
        }
        let chrome = list.filter { ($0[kCGWindowOwnerName as String] as? String) == "Google Chrome" && ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let win = chrome.max(by: { area($0) < area($1) }), let id = win[kCGWindowNumber as String] as? CGWindowID else { tasksPanel.thumbnail = nil; return }
        thumbBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution])
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbBusy = false
                if let img { self.tasksPanel.thumbnail = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)) }
            }
        }
    }

    func refreshTasksPanel() {
        updateWidgetTaskState()
        updateThumbnailTimer()
        let visible = tasks.tasks.filter { t in
            t.status == .running || t.status == .planning || t.status == .waiting || Date().timeIntervalSince(t.startedAt) < 15 * 60
        }
        if visible.isEmpty || !showTasksPanel || panelDismissed { tasksPanel.hide(); return }
        tasksPanel.render(visible)
        tasksPanel.show(above: overlay.panel.frame)
    }

    @objc func toggleTasksPanel(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!showTasksPanel, forKey: "showTasksPanel")
        sender.state = showTasksPanel ? .on : .off
        refreshTasksPanel()
    }
    @objc func cancelAllTasks() { tasks.cancelAll() }

    @objc func toggleMute(_ sender: Any?) { setMuted(!muted) }
    /// Silencia o activa la voz. Al silenciar en mitad de una locución, la corta y deja el texto en pantalla.
    func setMuted(_ m: Bool) {
        UserDefaults.standard.set(m, forKey: "mutedVoice")
        overlay.setMuted(m)
        muteMenuItem?.state = m ? .on : .off
        logApp(m ? "Voz silenciada (solo texto)" : "Voz activada")
        if m && state == .speaking {
            speaker.onFinish = nil
            speakWatchdog?.cancel()
            speaker.stop()
            listener.setEchoActive(false)
            overlay.showPause(false)
            if processDone { finishSpeaking() }
        }
        if state == .idle { statusLine.title = m ? "Voz silenciada" : "Esperando \"hey claude\"" }
    }
    @objc func clearFinishedTasks() { tasks.clearFinished() }

    /// Botón ■ del widget: corta a Claude (hablando o generando) y sigue escuchando.
    func pausePressed() {
        switch state {
        case .speaking:
            interrupt()
        case .thinking:
            claude.cancel()
            processDone = true
            logConv("< (interrumpido por el usuario)")
            enterListening(followUp: true)
        default:
            break
        }
    }

    /// Botón ✕ del widget: termina la conversación de inmediato y cierra el widget.
    func cancelPressed() {
        promoteWork?.cancel(); promoteWork = nil
        if let d = pendingTask { pendingTask = nil; tasks.finish(d, status: .cancelled, message: nil) }
        speakWatchdog?.cancel()
        speaker.onFinish = nil
        speaker.stop()
        if !processDone {
            claude.interruptTurn()
            processDone = true
            logConv("< (cancelado por el usuario)")
        }
        overlayLastReply = ""
        goIdle(immediate: true)
    }

    /// Tecla, Siri o menú: escucha sin palabra de activación.
    @objc func manualListen() {
        logApp("Disparo manual (tecla, Siri o menú) en estado \(state)")
        switch state {
        case .idle: enterListening(followUp: true)
        case .speaking: interrupt()
        case .listening:
            let cmd = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { commit(cmd) }
        case .thinking: break
        }
    }

    @objc func newConversation() {
        claude.stop()
        clearSession()
        logConv("--- nueva conversación ---")
        if state == .idle { speak("Empezamos de cero.", thenIdle: true) }
    }
    @objc func openHistory() { historyWindow.show() }

    /// Retoma una conversación anterior por su sesión.
    func resumeSession(_ sid: String) {
        claude.stop()
        writeSession(sid)
        touchSessionTime()
        logConv("--- retomada la sesión \(sid) ---")
        if state == .idle {
            overlay.show()
            speak("Listo, retomo esa conversación.", thenIdle: false)
        }
    }
    @objc func openContext() { NSWorkspace.shared.open(contextFile) }
    @objc func openVocab() {
        if !FileManager.default.fileExists(atPath: vocabFile.path) { try? "# Palabras que el reconocedor debe conocer (una por línea)\nClaude\n".write(to: vocabFile, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(vocabFile)
    }
    @objc func openCorrections() {
        if !FileManager.default.fileExists(atPath: correctionsFile.path) {
            try? "# Correcciones de dictado: lo que oye el reconocedor => lo que quisiste decir (una por línea).\n# Varias formas a la izquierda separadas por |. No distingue mayúsculas y solo cambia palabras completas.\nchef.com | enchef.com | chef punto com | chase.com | chest.com => chess.com\n".write(to: correctionsFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(correctionsFile)
    }
    @objc func reloadConfig() {
        listener.vocab = loadVocab()
        listener.restart()
        statusLine.title = "Configuración recargada"
    }
    @objc func quit() { NSApp.terminate(nil) }

    /// Apaga el proceso de conversación y los de todas las tareas.
    func shutdownProcesses() {
        speaker.neural.stop()
        claude.stop()
        for t in tasks.running { t.process?.cancel() }
    }

    // MARK: Menú, tecla y disparador

    private func setIcon(_ name: String) {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Claude Voice") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Claude Voice") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "✳︎"
        }
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Iniciando…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let listen = NSMenuItem(title: "Escuchar ahora", action: #selector(manualListen), keyEquivalent: "")
        listen.target = self
        menu.addItem(listen)
        listenMenuItem = listen
        let typed = NSMenuItem(title: "Escribir una orden…", action: #selector(openInput), keyEquivalent: "")
        typed.target = self
        menu.addItem(typed)
        typeMenuItem = typed
        let newConv = NSMenuItem(title: "Nueva conversación", action: #selector(newConversation), keyEquivalent: "")
        newConv.target = self; menu.addItem(newConv)
        menu.addItem(.separator())
        let panelItem = NSMenuItem(title: "Mostrar panel de tareas", action: #selector(toggleTasksPanel(_:)), keyEquivalent: "")
        panelItem.target = self; panelItem.state = showTasksPanel ? .on : .off; menu.addItem(panelItem)
        let muteItem = NSMenuItem(title: "Silenciar la voz (solo texto)", action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self; muteItem.state = muted ? .on : .off; menu.addItem(muteItem)
        muteMenuItem = muteItem
        let cancelTasks = NSMenuItem(title: "Cancelar tareas en curso", action: #selector(cancelAllTasks), keyEquivalent: "")
        cancelTasks.target = self; menu.addItem(cancelTasks)
        let clearTasks = NSMenuItem(title: "Limpiar tareas terminadas", action: #selector(clearFinishedTasks), keyEquivalent: "")
        clearTasks.target = self; menu.addItem(clearTasks)
        remindersLine = NSMenuItem(title: "Sin recordatorios pendientes", action: nil, keyEquivalent: "")
        remindersLine.isEnabled = false
        menu.addItem(remindersLine)
        usageLine = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        usageLine.target = self
        menu.addItem(usageLine)
        updateUsageLine()
        UsageStore.shared.onChange = { [weak self] in self?.updateUsageLine(); self?.checkUsageAlert() }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        for (t, s) in [("Historial de conversaciones", #selector(openHistory)),
                       ("Editar contexto personal", #selector(openContext)),
                       ("Editar vocabulario", #selector(openVocab)),
                       ("Editar correcciones de dictado", #selector(openCorrections)),
                       ("Recargar configuración", #selector(reloadConfig))] {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; menu.addItem(i)
        }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Salir de Claude Voice", action: #selector(quit), keyEquivalent: "q")
        q.target = self; menu.addItem(q)
        statusItem.menu = menu
    }

    static let hotkeyPresets: [(String, UInt32, UInt32)] = [
        ("⌥⌘C", UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey)),
        ("⌥⌘T", UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey)),
        ("⌥⌘V", UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey)),
        ("⌥⌘Espacio", UInt32(kVK_Space), UInt32(cmdKey | optionKey)),
        ("⌃⌥Espacio", UInt32(kVK_Space), UInt32(controlKey | optionKey)),
        ("⌃Espacio", UInt32(kVK_Space), UInt32(controlKey)),
        ("F5", UInt32(kVK_F5), 0),
        ("F6", UInt32(kVK_F6), 0),
    ]
    static var listenHotkey: Int { UserDefaults.standard.object(forKey: "hotkeyListen") as? Int ?? 0 }
    static var typeHotkey: Int { UserDefaults.standard.object(forKey: "hotkeyType") as? Int ?? 1 }

    func reregisterHotkeys() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let r = hotKeyRef2 { UnregisterEventHotKey(r); hotKeyRef2 = nil }
        let l = Controller.hotkeyPresets[min(Controller.listenHotkey, Controller.hotkeyPresets.count - 1)]
        let t = Controller.hotkeyPresets[min(Controller.typeHotkey, Controller.hotkeyPresets.count - 1)]
        RegisterEventHotKey(l.1, l.2, EventHotKeyID(signature: OSType(0x434C5644), id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        if Controller.typeHotkey != Controller.listenHotkey {
            RegisterEventHotKey(t.1, t.2, EventHotKeyID(signature: OSType(0x434C5644), id: 2), GetApplicationEventTarget(), 0, &hotKeyRef2)
        }
        listenMenuItem?.title = "Escuchar ahora (\(l.0))"
        typeMenuItem?.title = "Escribir una orden… (\(t.0))"
    }

    /// Esc cancela la orden en curso (como el botón ■). Se registra solo mientras la app no está en reposo,
    /// así en reposo la tecla sigue llegando a la app activa como siempre.
    private func updateEscapeHotkey() {
        if state == .idle {
            if let r = escHotKeyRef { UnregisterEventHotKey(r); escHotKeyRef = nil }
        } else if escHotKeyRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x434C5644), id: 3), GetApplicationEventTarget(), 0, &escHotKeyRef)
        }
    }

    private func setupHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async {
                switch hk.id {
                case 2: controller.openInput()
                case 3:
                    let now = Date()
                    if now.timeIntervalSince(controller.lastEscape) < 0.8 {
                        controller.lastEscape = .distantPast
                        logApp("Doble Esc: cancelar en estado \(controller.state)")
                        controller.cancelPressed()
                    } else {
                        controller.lastEscape = now
                        controller.overlay.setTitle("Esc otra vez para cancelar")
                    }
                default: controller.manualListen()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        reregisterHotkeys()
    }

}

// MARK: - App

var controller: Controller!

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?
    func applicationWillTerminate(_ n: Notification) { controller?.shutdownProcesses() }
    func applicationDidFinishLaunching(_ n: Notification) {
        rotateAppLog()
        signal(SIGPIPE, SIG_IGN)
        killOrphanClaudeProcesses()
        // Si nos cierran con kill/pkill, apagamos antes a los procesos hijos
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { controller?.shutdownProcesses(); exit(0) }
        src.resume()
        signal(SIGTERM, SIG_IGN)
        termSource = src
        controller = Controller()
        controller.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
