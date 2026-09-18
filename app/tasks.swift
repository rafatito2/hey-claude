// Tareas largas en segundo plano y panel visual de progreso.
import AppKit
import UserNotifications

// MARK: - Modelo

enum TaskStepState { case pending, current, done }

struct TaskStep {
    var text: String
    var state: TaskStepState
}

enum LongTaskStatus: String { case planning = "Planificando", waiting = "Esperando confirmación", running = "En curso", done = "Terminada", failed = "Falló", cancelled = "Cancelada", timedOut = "Tiempo agotado" }

final class LongTask {
    let id = UUID().uuidString
    let title: String
    var status: LongTaskStatus = .planning
    var steps: [TaskStep] = []
    var milestones: [String] = []
    var lastToolLabel = ""
    var result: String? = nil
    var planSummary = ""
    let startedAt = Date()
    var runStartedAt: Date? = nil
    var deadline: Date
    var toolCalls = 0
    var process: PersistentClaude?
    private var buffer = ""

    init(title: String, timeout: TimeInterval) {
        self.title = title
        self.deadline = Date().addingTimeInterval(timeout)
    }

    var elapsedText: String {
        let secs = Int(Date().timeIntervalSince(runStartedAt ?? startedAt))
        return secs < 60 ? "\(secs) s" : "\(secs / 60) min \(secs % 60) s"
    }

    var lastMilestone: String { milestones.last ?? (steps.first { $0.state == .current }?.text ?? lastToolLabel) }

    /// Procesa texto en streaming y devuelve las frases que hay que decir en voz alta.
    func ingest(_ delta: String) -> [String] {
        buffer += delta
        // Si Claude pega dos marcadores en la misma línea, los separamos
        buffer = rx(#"(?<=\S)[ \t]*(?=(?:PASO\s*\d+\s*:|HITO:|RESULTADO:|PLAN:))"#).stringByReplacingMatches(in: buffer, range: NSRange(location: 0, length: (buffer as NSString).length), withTemplate: "\n")
        var spoken: [String] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: nl)...])
            if let s = handle(line: line) { spoken.append(s) }
        }
        return spoken
    }

    /// Al terminar el turno, procesa lo que quedó sin salto de línea.
    func flush() -> [String] {
        let line = buffer.trimmingCharacters(in: .whitespaces)
        buffer = ""
        guard !line.isEmpty else { return [] }
        return handle(line: line).map { [$0] } ?? []
    }

    private func handle(line: String) -> String? {
        guard !line.isEmpty else { return nil }
        let upper = line.uppercased()
        if upper.hasPrefix("PLAN:") {
            planSummary = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if status == .running { steps.removeAll() }   // plan actualizado: el diagrama se reconstruye
            return planSummary.isEmpty ? nil : planSummary
        }
        if let m = rx(#"^(\d+)[.)]\s+(.+)$"#).firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            // Línea numerada del plan
            let text = (line as NSString).substring(with: m.range(at: 2))
            if steps.count < 8 { steps.append(TaskStep(text: text, state: .pending)) }
            return nil
        }
        if upper.hasPrefix("PASO") {
            // "PASO 2: texto"
            if let m = rx(#"^PASO\s*(\d+)\s*[:.-]\s*(.*)$"#).firstMatch(in: upper, range: NSRange(location: 0, length: (upper as NSString).length)) {
                let n = Int((upper as NSString).substring(with: m.range(at: 1))) ?? 0
                let text = (line as NSString).substring(with: m.range(at: 2))
                for i in steps.indices { if i < n - 1 { steps[i].state = .done } else if i == n - 1 { steps[i].state = .current } }
                if n > steps.count, !text.isEmpty { steps.append(TaskStep(text: text, state: .current)) }
                return text.isEmpty ? nil : text
            }
        }
        if upper.hasPrefix("HITO:") {
            let text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            milestones.append(text)
            advanceByText(text)
            return text
        }
        if upper.hasPrefix("RESULTADO:") {
            let text = line.dropFirst(10).trimmingCharacters(in: .whitespaces)
            result = text
            for i in steps.indices { steps[i].state = .done }
            return text
        }
        advanceByText(line)
        return nil
    }

    /// Si el texto se parece a un paso pendiente, lo marca como actual (y los anteriores como hechos).
    private func advanceByText(_ text: String) {
        let words = Set(normalize(text).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 4 })
        guard words.count >= 2 else { return }
        var best = -1; var bestScore = 0.0
        for (i, st) in steps.enumerated() where st.state != .done {
            let sw = Set(normalize(st.text).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 4 })
            guard !sw.isEmpty else { continue }
            let common = Double(words.intersection(sw).count)
            let score = common / Double(sw.count)
            if common >= 2 && score > bestScore { best = i; bestScore = score }
        }
        guard best >= 0, bestScore >= 0.4 else { return }
        for i in steps.indices { if i < best { steps[i].state = .done } else if i == best { steps[i].state = .current } }
    }

    var lastActivity = Date()
}

// MARK: - Gestor

final class TaskManager {
    private(set) var tasks: [LongTask] = []
    var onChange: (() -> Void)?
    var announce: ((String) -> Void)?
    private var timer: Timer?
    static let maxToolCalls = 400

    init() {
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    var running: [LongTask] { tasks.filter { $0.status == .running || $0.status == .planning || $0.status == .waiting } }

    func add(_ t: LongTask) { tasks.insert(t, at: 0); onChange?() }

    func finish(_ t: LongTask, status: LongTaskStatus, message: String?) {
        guard t.status == .running || t.status == .planning || t.status == .waiting else { return }
        t.status = status
        if status != .done { t.process?.cancel() }
        t.process = nil
        onChange?()
        let body = message ?? (status == .done ? "Tarea terminada" : status.rawValue)
        notify(title: t.title, body: body)
        if let message { announce?(message) }
    }

    func cancel(_ t: LongTask) {
        finish(t, status: .cancelled, message: "Tarea cancelada: \(t.title).")
    }

    func cancelAll() { running.forEach { cancel($0) } }

    /// Quita de la lista las tareas que ya no corren.
    func clearFinished() {
        tasks.removeAll { $0.status != .running && $0.status != .planning && $0.status != .waiting }
        onChange?()
    }
    var hasFinished: Bool { tasks.contains { $0.status != .running && $0.status != .planning && $0.status != .waiting } }

    private func tick() {
        for t in running where t.status == .running && Date() > t.deadline {
            finish(t, status: .timedOut, message: "Se acabó el tiempo para la tarea: \(t.title).")
        }
        if !running.isEmpty { onChange?() }   // refresca el tiempo transcurrido
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Panel visual

final class TasksPanel: NSObject {
    let panel: NSPanel
    private let effect: NSVisualEffectView
    private let stack = NSStackView()
    private let closeButton = ClickButton(frame: .zero)
    private var pulseTimer: Timer?
    private var pulseOn = false
    private var currentDots: [NSView] = []
    var onCancel: ((LongTask) -> Void)?
    var onClose: (() -> Void)?
    var isLight: Bool { UserDefaults.standard.bool(forKey: "lightTheme") }
    private var fg: NSColor { isLight ? .black : .white }
    private let width: CGFloat = 520

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        effect.maskImage = roundedMask(radius: 22)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Ocultar") {
            closeButton.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        }
        closeButton.toolTip = "Ocultar panel de tareas"
        effect.addSubview(closeButton)
        panel.alphaValue = 0
        super.init()
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        pulseTimer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.pulse() }
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }

    @objc private func closePressed() { hide(); onClose?() }

    private func pulse() {
        guard panel.isVisible, !currentDots.isEmpty else { return }
        pulseOn.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            for d in currentDots { d.animator().alphaValue = pulseOn ? 1 : 0.35 }
        }
    }

    func applyTheme() {
        effect.material = isLight ? .popover : .hudWindow
        effect.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        closeButton.contentTintColor = fg.withAlphaComponent(0.6)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1, lines: Int = 2) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = fg.withAlphaComponent(alpha)
        l.maximumNumberOfLines = lines
        l.lineBreakMode = .byTruncatingTail
        l.preferredMaxLayoutWidth = width - 90
        return l
    }

    private func dot(_ state: TaskStepState) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.widthAnchor.constraint(equalToConstant: 12).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        switch state {
        case .done: v.layer?.backgroundColor = claudeOrange.cgColor
        case .current: v.layer?.backgroundColor = claudeOrange.cgColor; v.layer?.borderWidth = 2; v.layer?.borderColor = claudeOrange.withAlphaComponent(0.35).cgColor; currentDots.append(v)
        case .pending: v.layer?.backgroundColor = fg.withAlphaComponent(0.18).cgColor
        }
        return v
    }

    /// Reconstruye el contenido con las tareas dadas.
    func render(_ tasks: [LongTask]) {
        applyTheme()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        currentDots.removeAll()
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.addArrangedSubview(label("Tareas de Claude", size: 13, weight: .semibold, alpha: 0.6, lines: 1))
        if tasks.contains(where: { $0.status != .running && $0.status != .planning && $0.status != .waiting }) {
            clearButton.bezelStyle = .inline
            clearButton.controlSize = .small
            clearButton.font = .systemFont(ofSize: 11)
            clearButton.target = self
            clearButton.action = #selector(clearPressed)
            clearButton.toolTip = "Quitar las tareas terminadas"
            headerRow.addArrangedSubview(clearButton)
        }
        stack.addArrangedSubview(headerRow)
        for t in tasks {
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 6
            let titleRow = NSStackView()
            titleRow.orientation = .horizontal
            titleRow.spacing = 8
            titleRow.addArrangedSubview(label(t.title, size: 15, weight: .semibold, lines: 2))
            if t.status == .running || t.status == .planning || t.status == .waiting {
                let cancel = ClickButton(frame: .zero)
                cancel.isBordered = false
                cancel.imagePosition = .imageOnly
                if let img = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Cancelar") {
                    cancel.image = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
                }
                cancel.contentTintColor = fg.withAlphaComponent(0.6)
                cancel.toolTip = "Cancelar tarea"
                cancel.target = self
                cancel.action = #selector(cancelPressed(_:))
                cancel.identifier = NSUserInterfaceItemIdentifier(t.id)
                titleRow.addArrangedSubview(cancel)
            }
            box.addArrangedSubview(titleRow)
            let statusText: String = {
                switch t.status {
                case .running:
                    let since = Int(Date().timeIntervalSince(t.lastActivity))
                    let act = t.lastToolLabel.isEmpty ? "" : " · \(t.lastToolLabel) (hace \(since) s, \(t.toolCalls) acciones)"
                    return "\(t.status.rawValue) · \(t.elapsedText)" + act
                case .done: return "Terminada en \(t.elapsedText)"
                default: return t.status.rawValue
                }
            }()
            box.addArrangedSubview(label(statusText, size: 12, alpha: 0.65, lines: 1))
            if !t.planSummary.isEmpty && t.status == .waiting {
                box.addArrangedSubview(label(t.planSummary, size: 12, alpha: 0.8, lines: 3))
            }
            if !t.steps.isEmpty {
                let timeline = NSStackView()
                timeline.orientation = .vertical
                timeline.alignment = .leading
                timeline.spacing = 5
                for step in t.steps {
                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.spacing = 10
                    row.alignment = .centerY
                    row.addArrangedSubview(dot(step.state))
                    row.addArrangedSubview(label(step.text, size: 12, weight: step.state == .current ? .semibold : .regular, alpha: step.state == .pending ? 0.5 : 0.9, lines: 2))
                    timeline.addArrangedSubview(row)
                }
                box.addArrangedSubview(timeline)
            }
            if let last = t.milestones.last, t.status == .running {
                box.addArrangedSubview(label("Último hito: \(last)", size: 12, alpha: 0.75, lines: 2))
            }
            if let r = t.result, t.status != .running {
                box.addArrangedSubview(label(r, size: 12, alpha: 0.85, lines: 3))
            }
            stack.addArrangedSubview(box)
        }
        stack.layoutSubtreeIfNeeded()
        let h = max(80, stack.fittingSize.height)
        let f = panel.frame
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: width, height: h), display: true)
        closeButton.frame = NSRect(x: width - 36, y: h - 34, width: 24, height: 24)
    }

    @objc private func clearPressed() { onClear?() }

    @objc private func cancelPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onCancelId?(id)
    }
    var onCancelId: ((String) -> Void)?
    var onClear: (() -> Void)?
    private let clearButton = NSButton(title: "Limpiar", target: nil, action: nil)

    /// Se coloca justo encima del widget principal.
    func show(above widgetFrame: NSRect) {
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(x: widgetFrame.maxX - width, y: widgetFrame.maxY + 12))
        _ = f
        if !panel.isVisible { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }
}

// MARK: - Detección por voz

let longTaskRegex = try! NSRegularExpression(pattern: #"\b(en segundo plano|tarea larga|in the background|long task|juega|jugar|gana|ganar|partida|termina el|completa el|investiga a fondo|haz un informe|monitorea|vigila|automatiza|descarga todos|organiza|revisa todos|resume todos|play a game|win a game|research thoroughly|write a report|monitor|automate)\b"#)
let taskStatusRegex = try! NSRegularExpression(pattern: #"^(como vas|como va|como va la tarea|estado de la tarea|que estas haciendo|en que vas|how's it going|how is it going|status|task status|what are you doing)\b"#)
let taskCancelRegex = try! NSRegularExpression(pattern: #"^(cancela la tarea|cancela las tareas|deten la tarea|para la tarea|cancel the task|stop the task|abort)\b"#)
let confirmRegex = try! NSRegularExpression(pattern: #"^(si|sí|dale|adelante|ok|okay|hazlo|vamos|procede|de acuerdo|claro|yes|go ahead|do it|start|sure|go)\b"#)
let denyRegex = try! NSRegularExpression(pattern: #"^(no|cancela|dejalo|olvidalo|mejor no|nah|nope|forget it|never mind|cancel)\b"#)
let steerRegex = try! NSRegularExpression(pattern: #"\b(mas rapido|rapido|apurate|date prisa|acelera|mas lento|despacio|sigue|continua|cambia|mejor|en vez|no hagas|deja de|intenta|prueba|usa|hazlo|ve por|ataca|defiende|faster|hurry|slower|continue|keep going|change|instead|don't|stop doing|try|use|go for)\b"#)
let explicitNewTaskRegex = try! NSRegularExpression(pattern: #"\b(en segundo plano|otra tarea|nueva tarea|ademas|tambien|in the background|another task|new task|also)\b"#)
let taskTimeoutRegex = try! NSRegularExpression(pattern: #"\b(tomate|tienes|te doy|maximo|take|you have)\s+(\S+)\s+(minutos?|horas?|hora|minutes?|hours?|hour)\b"#)

/// Instrucciones que recibe el proceso de una tarea larga.
let taskPrompt = """

Estás ejecutando una TAREA LARGA en segundo plano y el usuario no está mirando: sigue un protocolo estricto de texto, porque la app solo lee en voz alta ciertas líneas.
- Cuando te pidan el plan: escribe una línea "PLAN: <dos frases: qué harás y cuánto tardarás>" y luego hasta 6 pasos numerados ("1. ...", "2. ..."). No ejecutes nada hasta que te digan "adelante".
- Al ejecutar, al empezar cada paso escribe una línea "PASO n: <texto corto>". Cuando ocurra algo importante (progreso notable, problema, cambio de plan) escribe "HITO: <una frase>". No narres cada acción menor; el resto del texto no se lee en voz alta.
- Si algo falla, reintenta de otra forma antes de rendirte. No pidas confirmaciones intermedias: decide tú.
- Al terminar escribe una única línea "RESULTADO: <una o dos frases con el resultado>".
- Juego limpio: nunca juegues contra personas con ayuda de IA en sitios como chess.com; usa los bots del sitio o el modo de análisis.
- VELOCIDAD en Chrome: no leas la página completa ni tomes capturas en cada paso. Extrae el estado de forma compacta con javascript_tool (por ejemplo, para un tablero de ajedrez, devuelve solo la lista de piezas y casillas o el FEN). Agrupa varias acciones seguidas en una sola llamada con browser_batch. Actúa sin volver a leer la página si ya sabes lo que va a pasar.
- JUEGOS: si el juego lo permite, instala y usa un motor local (por ejemplo `brew install stockfish` y consúltalo con el FEN) para decidir en milisegundos en vez de razonar cada jugada.
"""

/// Herramientas ampliadas solo para tareas (el usuario las confirma al aprobar el plan).
let taskExtraTools = "Bash(python3:*),Bash(node:*),Bash(npm:*),Bash(brew install:*),Bash(brew list:*),Bash(curl:*),Bash(git:*),Bash(chmod +x:*),Bash(pip3:*),Write(~/claude-voice/tareas/**),Edit(~/claude-voice/tareas/**),Bash(~/claude-voice/tareas/*)"
