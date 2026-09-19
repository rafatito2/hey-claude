// Calendarios y Recordatorios de Apple por EventKit (rápido: consulta directa, sin AppleScript).
// Uso:
//   calendario calendarios
//   calendario listar DESDE HASTA [calendario]         -> uid | calendario | inicio | fin | título (una línea por evento)
//   calendario duplicados DESDE HASTA [calendario]     -> repetidos en el mismo calendario (UIDS_A_BORRAR) y en calendarios distintos
//   calendario borrar UID [UID...]
//   calendario crear "título" "YYYY-MM-DD HH:MM" "YYYY-MM-DD HH:MM" [calendario]
//   calendario borrar-calendario "nombre"              -> quita un calendario o suscripción entera
//   calendario recordatorios [lista]                   -> pendientes: id | lista | vence | título
//   calendario recordatorio-crear "texto" ["YYYY-MM-DD HH:MM"] [lista]
//   calendario recordatorio-completar ID
// Fechas: YYYY-MM-DD o "YYYY-MM-DD HH:MM". Sale con código 2 si falta permiso.
import EventKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String, _ code: Int32 = 1) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(code) }
guard let cmd = args.first else {
    print(try! String(contentsOfFile: CommandLine.arguments[0] + ".swift", encoding: .utf8).split(separator: "\n").prefix(12).joined(separator: "\n")); exit(1)
}
let store = EKEventStore()
let fmtIn = DateFormatter(); fmtIn.dateFormat = "yyyy-MM-dd HH:mm"; fmtIn.locale = Locale(identifier: "en_US_POSIX")
let fmtDay = DateFormatter(); fmtDay.dateFormat = "yyyy-MM-dd"; fmtDay.locale = Locale(identifier: "en_US_POSIX")
func date(_ s: String) -> Date { fmtIn.date(from: s) ?? fmtDay.date(from: s) ?? { fail("fecha inválida: \(s) (usa YYYY-MM-DD o \"YYYY-MM-DD HH:MM\")") }() }
func fmt(_ d: Date?) -> String { d.map { fmtIn.string(from: $0) } ?? "" }

func access(_ type: EKEntityType) {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    let handler: (Bool, Error?) -> Void = { g, _ in ok = g; sem.signal() }
    if #available(macOS 14, *) {
        if type == .event { store.requestFullAccessToEvents(completion: handler) } else { store.requestFullAccessToReminders(completion: handler) }
    } else { store.requestAccess(to: type, completion: handler) }
    sem.wait()
    if !ok { fail("sin permiso de \(type == .event ? "Calendario" : "Recordatorios"): actívalo en Ajustes del Sistema → Privacidad y seguridad", 2) }
}
func calendar(named name: String, _ type: EKEntityType = .event) -> EKCalendar {
    let cals = store.calendars(for: type)
    if let c = cals.first(where: { $0.title == name }) ?? cals.first(where: { $0.title.lowercased() == name.lowercased() }) ?? cals.first(where: { $0.title.lowercased().contains(name.lowercased()) }) { return c }
    fail("no existe el calendario \"\(name)\"; tengo: " + cals.map { $0.title }.joined(separator: ", "))
}
func events(_ from: String, _ to: String, _ cal: String?) -> [EKEvent] {
    let cals = cal.map { [calendar(named: $0)] }
    let pred = store.predicateForEvents(withStart: date(from), end: date(to), calendars: cals)
    return store.events(matching: pred).sorted { ($0.startDate, $0.title) < ($1.startDate, $1.title) }
}
func line(_ e: EKEvent) -> String { "\(e.calendarItemIdentifier)\t\(e.calendar.title)\t\(fmt(e.startDate))\t\(fmt(e.endDate))\t\(e.title ?? "")" }

switch cmd {
case "calendarios":
    access(.event)
    for c in store.calendars(for: .event) {
        let kind = c.isSubscribed ? "suscripción" : c.allowsContentModifications ? "editable" : "solo lectura"
        print("\(c.title)\t\(kind)\t\(c.source.title)")
    }
case "listar":
    guard args.count >= 3 else { fail("uso: listar DESDE HASTA [calendario]") }
    access(.event)
    for e in events(args[1], args[2], args.count > 3 ? args[3] : nil) { print(line(e)) }
case "duplicados":
    guard args.count >= 3 else { fail("uso: duplicados DESDE HASTA [calendario]") }
    access(.event)
    let evs = events(args[1], args[2], args.count > 3 ? args[3] : nil)
    var same: [String: [EKEvent]] = [:], cross: [String: [EKEvent]] = [:]
    for e in evs {
        let key = "\(fmt(e.startDate))|\(fmt(e.endDate))|\((e.title ?? "").trimmingCharacters(in: .whitespaces).lowercased())"
        same["\(e.calendar.calendarIdentifier)|\(key)", default: []].append(e)
        cross[key, default: []].append(e)
    }
    let dups = same.filter { $0.value.count > 1 }
    let multi = cross.filter { Set($0.value.map { $0.calendar.calendarIdentifier }).count > 1 }
    if dups.isEmpty && multi.isEmpty { print("Sin duplicados."); exit(0) }
    if !dups.isEmpty {
        let extra = dups.values.reduce(0) { $0 + $1.count - 1 }
        print("\(dups.count) grupos repetidos dentro del mismo calendario, \(extra) eventos sobrantes (se conserva uno por grupo):")
        for g in dups.values.sorted(by: { $0[0].startDate < $1[0].startDate }) {
            print("- \(g[0].title ?? "") | \(g[0].calendar.title) | \(fmt(g[0].startDate)) -> \(fmt(g[0].endDate)) | \(g.count) copias | borrar: " + g.dropFirst().map { $0.calendarItemIdentifier }.joined(separator: " "))
        }
        print("UIDS_A_BORRAR: " + dups.values.flatMap { $0.dropFirst().map { $0.calendarItemIdentifier } }.joined(separator: " "))
    }
    if !multi.isEmpty {
        print("\(multi.count) eventos que están en más de un calendario (decidir cuál conservar; si uno es una suscripción, conviene borrar-calendario):")
        var byCal: [String: [String]] = [:]
        for g in multi.values.sorted(by: { $0[0].startDate < $1[0].startDate }) {
            var seen = Set<String>(); var parts: [String] = []
            for e in g where !seen.contains(e.calendar.calendarIdentifier) {
                seen.insert(e.calendar.calendarIdentifier); parts.append("\(e.calendar.title): \(e.calendarItemIdentifier)")
                byCal[e.calendar.title, default: []].append(e.calendarItemIdentifier)
            }
            print("- \(g[0].title ?? "") | \(fmt(g[0].startDate)) -> \(fmt(g[0].endDate)) | " + parts.joined(separator: " ; "))
        }
        for (c, ids) in byCal { print("UIDS_EN_\(c.replacingOccurrences(of: " ", with: "_")): " + ids.joined(separator: " ")) }
    }
case "borrar":
    guard args.count >= 2 else { fail("uso: borrar UID [UID...]") }
    access(.event)
    var n = 0
    for uid in args.dropFirst() {
        guard let e = store.calendarItem(withIdentifier: uid) as? EKEvent else { print("no encontrado: \(uid)"); continue }
        guard e.calendar.allowsContentModifications else { print("no editable (suscripción \"\(e.calendar.title)\"): \(e.title ?? uid). Usa borrar-calendario."); continue }
        do { try store.remove(e, span: .futureEvents, commit: false); n += 1 } catch { print("error con \(uid): \(error.localizedDescription)") }
    }
    do { try store.commit() } catch { fail("no pude guardar: \(error.localizedDescription)") }
    print("Borrados: \(n)")
case "crear":
    guard args.count >= 4 else { fail("uso: crear \"título\" INICIO FIN [calendario]") }
    access(.event)
    let e = EKEvent(eventStore: store)
    e.title = args[1]; e.startDate = date(args[2]); e.endDate = date(args[3])
    e.calendar = args.count > 4 ? calendar(named: args[4]) : (store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first { $0.allowsContentModifications }!)
    do { try store.save(e, span: .thisEvent); print("Creado en \(e.calendar.title): \(e.calendarItemIdentifier)") } catch { fail("no pude crear: \(error.localizedDescription)") }
case "borrar-calendario":
    guard args.count >= 2 else { fail("uso: borrar-calendario \"nombre\"") }
    access(.event)
    let c = calendar(named: args[1])
    let n = store.events(matching: store.predicateForEvents(withStart: Date(timeIntervalSinceNow: -5 * 365 * 86400), end: Date(timeIntervalSinceNow: 5 * 365 * 86400), calendars: [c])).count
    do { try store.removeCalendar(c, commit: true); print("Calendario borrado: \(c.title) (\(n) eventos)") } catch { fail("no pude borrar el calendario: \(error.localizedDescription)") }
case "recordatorios":
    access(.reminder)
    let cals = args.count > 1 ? [calendar(named: args[1], .reminder)] : nil
    let sem = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)) { rs in
        for r in (rs ?? []).sorted(by: { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }) {
            print("\(r.calendarItemIdentifier)\t\(r.calendar.title)\t\(fmt(r.dueDateComponents?.date))\t\(r.title ?? "")")
        }
        sem.signal()
    }
    sem.wait()
case "recordatorio-crear":
    guard args.count >= 2 else { fail("uso: recordatorio-crear \"texto\" [\"YYYY-MM-DD HH:MM\"] [lista]") }
    access(.reminder)
    let r = EKReminder(eventStore: store)
    r.title = args[1]
    if args.count > 2, !args[2].isEmpty { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date(args[2])) }
    r.calendar = args.count > 3 ? calendar(named: args[3], .reminder) : store.defaultCalendarForNewReminders()
    do { try store.save(r, commit: true); print("Recordatorio creado en \(r.calendar.title): \(r.calendarItemIdentifier)") } catch { fail("no pude crear: \(error.localizedDescription)") }
case "recordatorio-completar":
    guard args.count >= 2 else { fail("uso: recordatorio-completar ID") }
    access(.reminder)
    guard let r = store.calendarItem(withIdentifier: args[1]) as? EKReminder else { fail("no encontrado") }
    r.isCompleted = true
    do { try store.save(r, commit: true); print("Completado: \(r.title ?? "")") } catch { fail("no pude guardar: \(error.localizedDescription)") }
default:
    fail("comando desconocido: \(cmd)")
}
