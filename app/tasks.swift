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
    var lastMilestoneAt = Date()
    var lastStatusRequestAt = Date.distantPast
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
        if !spoken.isEmpty { lastMilestoneAt = Date() }
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
        if t.runStartedAt != nil { appendTaskHistory(t, status: status, message: body) }
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

    static var statusInterval: TimeInterval { UserDefaults.standard.object(forKey: "taskStatusInterval") as? Double ?? 40 }

    private func tick() {
        for t in running where t.status == .running && Date() > t.deadline {
            finish(t, status: .timedOut, message: "Se acabó el tiempo para la tarea: \(t.title).")
        }
        // Si la tarea lleva un rato sin contar nada, se le pide una línea de estado (la responde entre dos acciones)
        let interval = TaskManager.statusInterval
        for t in running where t.status == .running {
            let quiet = Date().timeIntervalSince(t.lastMilestoneAt)
            let sinceAsk = Date().timeIntervalSince(t.lastStatusRequestAt)
            if quiet > interval && sinceAsk > interval, let p = t.process, p.isBusy {
                if p.steer("ESTADO: escribe ahora UNA línea \"HITO: <qué está pasando y qué vas a hacer>\" (una frase, en el idioma del usuario) y continúa la tarea sin detenerte.") {
                    t.lastStatusRequestAt = Date()
                }
            }
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

// MARK: - Historial

/// Las tareas terminadas quedan anotadas para que una tarea nueva pueda referirse a ellas ("vuelve a jugar contra...").
let taskHistoryFile = baseDir.appendingPathComponent("tareas/historial.txt")

func appendTaskHistory(_ t: LongTask, status: LongTaskStatus, message: String) {
    let outcome = (t.result?.isEmpty == false ? t.result! : message).replacingOccurrences(of: "\n", with: " ")
    let line = "\(t.title.replacingOccurrences(of: "\n", with: " ")) → \(status.rawValue): \(outcome.prefix(240))"
    try? FileManager.default.createDirectory(at: taskHistoryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    appendLine(taskHistoryFile, line)
}

/// Últimas tareas anotadas, una por línea (para el prompt del plan).
func recentTaskHistory(limit: Int = 5) -> String {
    guard let t = try? String(contentsOf: taskHistoryFile, encoding: .utf8) else { return "" }
    let lines = t.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    return lines.suffix(limit).map { "- " + $0 }.joined(separator: "\n")
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
    /// Captura de la ventana de Chrome que la tarea está usando (la pone el controlador cada pocos segundos).
    private let thumbView = NSImageView(frame: .zero)
    var thumbnail: NSImage? {
        didSet {
            thumbView.image = thumbnail
            let visible = thumbnail != nil
            if thumbView.isHidden != !visible { thumbView.isHidden = !visible; if let last = lastRendered { render(last) } }
        }
    }
    private var lastRendered: [LongTask]? = nil

    /// Cajita estilo terminal: "$ comando" en verde y la salida en gris, últimos comandos primero los más antiguos.
    private func terminalBox(_ entries: [TermEntry]) -> NSView {
        let box = NSView(frame: .zero)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.92).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let s = NSMutableAttributedString()
        let green = NSColor(calibratedRed: 0.45, green: 0.9, blue: 0.55, alpha: 1)
        let gray = NSColor.white.withAlphaComponent(0.72)
        let red = NSColor(calibratedRed: 1, green: 0.5, blue: 0.5, alpha: 1)
        for (i, e) in entries.suffix(3).enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: mono])) }
            let cmd = e.command.split(separator: "\n").map(String.init).joined(separator: " ")
            s.append(NSAttributedString(string: "$ ", attributes: [.font: mono, .foregroundColor: green]))
            s.append(NSAttributedString(string: String(cmd.prefix(160)), attributes: [.font: mono, .foregroundColor: NSColor.white]))
            if let out = e.output {
                let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map { String($0.prefix(110)) }
                let shown = lines.suffix(4)
                let body = (lines.count > shown.count ? "…\n" : "") + shown.joined(separator: "\n")
                if !body.isEmpty { s.append(NSAttributedString(string: "\n" + body, attributes: [.font: mono, .foregroundColor: e.failed ? red : gray])) }
            } else {
                s.append(NSAttributedString(string: "\n▍ ejecutando…", attributes: [.font: mono, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]))
            }
        }
        text.textStorage?.setAttributedString(s)
        box.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        let w = width - 40
        text.textContainer?.containerSize = NSSize(width: w - 20, height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let h = min(180, max(34, (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 30) + 16))
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: w),
            box.heightAnchor.constraint(equalToConstant: h),
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            text.topAnchor.constraint(equalTo: box.topAnchor),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    func render(_ tasks: [LongTask], conversationTerminal: [TermEntry] = []) {
        lastRendered = tasks
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
        if !conversationTerminal.isEmpty {
            let box = NSStackView(); box.orientation = .vertical; box.alignment = .leading; box.spacing = 6
            let running = conversationTerminal.last?.output == nil
            box.addArrangedSubview(label(running ? "Terminal · ejecutando" : "Terminal", size: 13, weight: .semibold, alpha: 0.8, lines: 1))
            box.addArrangedSubview(terminalBox(conversationTerminal))
            stack.addArrangedSubview(box)
        }
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
            if t.status == .running, let term = t.process?.terminal, !term.isEmpty, Date().timeIntervalSince(term.last!.at) < 300 {
                box.addArrangedSubview(terminalBox(term))
            }
            if t.status == .running, thumbnail != nil, thumbView.superview == nil {
                thumbView.imageScaling = .scaleProportionallyUpOrDown
                thumbView.wantsLayer = true
                thumbView.layer?.cornerRadius = 8
                thumbView.layer?.masksToBounds = true
                thumbView.layer?.borderWidth = 0.5
                thumbView.layer?.borderColor = fg.withAlphaComponent(0.2).cgColor
                thumbView.toolTip = "Lo que Claude está viendo en Chrome"
                thumbView.translatesAutoresizingMaskIntoConstraints = false
                thumbView.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
                thumbView.heightAnchor.constraint(equalToConstant: (width - 40) * 0.6).isActive = true
                thumbView.isHidden = false
                box.addArrangedSubview(thumbView)
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
- Al ejecutar, al empezar cada paso escribe una línea "PASO n: <texto corto>". Cuando ocurra algo importante (progreso notable, problema, cambio de plan) escribe "HITO: <una frase>", y como mínimo una línea HITO cada 3 o 4 acciones aunque no haya novedades grandes (en un juego: cada jugada tuya). No narres detalles menores; el resto del texto no se lee en voz alta.
- Si recibes un mensaje que empieza por "ESTADO:", contesta de inmediato con una sola línea HITO y sigue trabajando.
- Si algo falla, reintenta de otra forma antes de rendirte. No pidas confirmaciones intermedias: decide tú.
- Al terminar escribe una única línea "RESULTADO: <una o dos frases con el resultado>".
- Si la tarea tiene un riesgo ético o de reglas (por ejemplo usar un motor de ajedrez contra personas en chess.com viola su política de juego limpio y puede costar la cuenta), dilo en una frase dentro del PLAN y ejecútala igual: el usuario decide, tú no te niegas.
- VELOCIDAD en Chrome: no leas la página completa ni tomes capturas en cada paso. Extrae el estado de forma compacta con javascript_tool (por ejemplo, para un tablero de ajedrez, devuelve solo la lista de piezas y casillas o el FEN). Agrupa varias acciones seguidas en una sola llamada con browser_batch. Actúa sin volver a leer la página si ya sabes lo que va a pasar.
- AJEDREZ: para elegir jugadas usa el script listo `~/claude-voice/tareas/bestmove.sh "<FEN>"` (devuelve la mejor jugada en notación UCI, p. ej. e7e5; segundo argumento opcional: milisegundos de cálculo). No instales ni configures nada: si el script devuelve "error", juega con tu propio criterio y no insistas. Obtén el FEN del tablero con javascript_tool.
"""

/// Herramientas ampliadas solo para tareas (el usuario las confirma al aprobar el plan).
let taskExtraTools = "Bash(python3:*),Bash(node:*),Bash(npm:*),Bash(brew install:*),Bash(brew list:*),Bash(brew info:*),Bash(curl:*),Bash(git:*),Bash(chmod +x:*),Bash(pip3:*),Bash(stockfish:*),Bash(/opt/homebrew/bin/*),Bash(/usr/local/bin/*),Bash(which:*),Write(~/claude-voice/tareas/**),Edit(~/claude-voice/tareas/**),Bash(~/claude-voice/tareas/*),Bash(~/claude-voice/tareas/bestmove.sh:*),Bash(bash ~/claude-voice/tareas/*),Bash(python3 ~/claude-voice/tareas/*)"
