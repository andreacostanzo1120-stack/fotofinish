import Foundation
import SwiftUI
import UIKit

// MARK: - Impostazioni

final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var theme: Int = 0 { didSet { d.set(theme, forKey: "theme") } }
    @Published var textSize: Int = 0 { didSet { d.set(textSize, forKey: "textSize") } }
    @Published var leftToRight: Bool = true { didSet { d.set(leftToRight, forKey: "leftToRight") } }
    @Published var voiceOn: Bool = true { didSet { d.set(voiceOn, forKey: "voiceOn") } }
    @Published var holdMin: Double = 1.6 { didSet { d.set(holdMin, forKey: "holdMin") } }
    @Published var holdMax: Double = 2.6 { didSet { d.set(holdMax, forKey: "holdMax") } }
    @Published var maxFPS: Int = 240 { didSet { d.set(maxFPS, forKey: "maxFPS") } }
    @Published var remoteCorrection: Double = 0 { didSet { d.set(remoteCorrection, forKey: "remoteCorrection") } }
    @Published var fieldMode = false

    init() {
        if d.object(forKey: "theme") != nil { theme = d.integer(forKey: "theme") }
        if d.object(forKey: "textSize") != nil { textSize = d.integer(forKey: "textSize") }
        if d.object(forKey: "leftToRight") != nil { leftToRight = d.bool(forKey: "leftToRight") }
        if d.object(forKey: "voiceOn") != nil { voiceOn = d.bool(forKey: "voiceOn") }
        if d.object(forKey: "holdMin") != nil { holdMin = d.double(forKey: "holdMin") }
        if d.object(forKey: "holdMax") != nil { holdMax = d.double(forKey: "holdMax") }
        if d.object(forKey: "maxFPS") != nil { maxFPS = d.integer(forKey: "maxFPS") }
        if d.object(forKey: "remoteCorrection") != nil { remoteCorrection = d.double(forKey: "remoteCorrection") }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var typeRange: ClosedRange<DynamicTypeSize> {
        switch textSize {
        case 1: return DynamicTypeSize.xLarge...DynamicTypeSize.xLarge
        case 2: return DynamicTypeSize.accessibility1...DynamicTypeSize.accessibility1
        default: return DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5
        }
    }
}

// MARK: - Backup

struct StripBackup: Codable {
    var raceId: UUID
    var info: StripInfo
    var jpeg: String
}

struct BackupFile: Codable {
    var version: Int
    var athletes: [String]
    var sessions: [Session]
    var runs: [Run]
    var strips: [StripBackup]
}

// MARK: - Archivio

final class DataStore: ObservableObject {
    @Published var runs: [Run] = [] {
        didSet { save(runs, "runs.json") }
    }
    @Published var sessions: [Session] = [] {
        didSet { save(sessions, "sessions.json") }
    }
    @Published var athletes: [String] = ["Atleta 1"] {
        didSet { UserDefaults.standard.set(athletes, forKey: "athletes") }
    }

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "athletes"), !saved.isEmpty {
            athletes = saved
        }
        if let r: [Run] = load("runs.json") { runs = r }
        if let s: [Session] = load("sessions.json") { sessions = s }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: docs.appendingPathComponent(name), options: .atomic)
        }
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: docs.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Prove

    func addAssigning(_ run: Run) {
        var r = run
        place(&r)
        runs.insert(r, at: 0)
    }

    func update(_ run: Run) {
        if let i = runs.firstIndex(where: { $0.id == run.id }) {
            runs[i] = run
        }
    }

    func delete(ids: Set<UUID>) {
        runs.removeAll { ids.contains($0.id) }
    }

    func runs(forRace id: UUID) -> [Run] {
        runs.filter { $0.raceId == id }.sorted { $0.time < $1.time }
    }

    func assign(_ id: UUID, athlete: String) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        var r = runs[i]
        r.athlete = athlete
        r.series = nil
        r.rep = nil
        place(&r)
        runs[i] = r
    }

    func isPB(_ run: Run) -> Bool {
        let same = runs.filter { $0.athlete == run.athlete && $0.distance == run.distance }
        guard let best = same.map({ $0.time }).min() else { return false }
        return best == run.time
    }

    func seasonBest(athlete: String, distance: Double, year: Int) -> Double? {
        let cal = Calendar.current
        return runs
            .filter { $0.athlete == athlete && $0.distance == distance && cal.component(.year, from: $0.date) == year }
            .map { $0.time }
            .min()
    }

    // MARK: Allenamenti

    /// Prima casella (serie, ripetizione) ancora vuota per l'atleta
    func cellFor(athlete: String, session: Session, excluding runId: UUID?) -> (Int, Int)? {
        var used = Set<Int>()
        for r in runs where r.sessionId == session.id && r.athlete == athlete && r.id != runId {
            if let s = r.series, let p = r.rep {
                used.insert((s - 1) * session.plan.reps + (p - 1))
            }
        }
        for i in 0..<session.plan.total where !used.contains(i) {
            return (i / session.plan.reps + 1, i % session.plan.reps + 1)
        }
        return nil
    }

    private func place(_ run: inout Run) {
        guard let sid = run.sessionId, let session = sessions.first(where: { $0.id == sid }) else { return }
        if run.athlete.isEmpty {
            run.series = nil
            run.rep = nil
            return
        }
        if let c = cellFor(athlete: run.athlete, session: session, excluding: run.id) {
            run.series = c.0
            run.rep = c.1
        } else {
            run.series = nil
            run.rep = nil
        }
    }

    func cellRun(_ s: Session, _ athlete: String, _ series: Int, _ rep: Int) -> Run? {
        runs.first { $0.sessionId == s.id && $0.athlete == athlete && $0.series == series && $0.rep == rep }
    }

    func setCell(_ session: Session, athlete: String, series: Int, rep: Int, time: Double?) {
        var list = runs
        let idx = list.firstIndex {
            $0.sessionId == session.id && $0.athlete == athlete && $0.series == series && $0.rep == rep
        }
        if let t = time {
            if let i = idx {
                list[i].time = t
            } else {
                let r = Run(athlete: athlete, distance: session.plan.distance, mode: .manual, time: t,
                            sessionId: session.id, series: series, rep: rep)
                list.insert(r, at: 0)
            }
        } else if let i = idx {
            list.remove(at: i)
        }
        runs = list
    }

    func sessionTimes(_ s: Session, athlete: String) -> [Double] {
        var out: [Double] = []
        for si in 1...max(1, s.plan.series) {
            for ri in 1...max(1, s.plan.reps) {
                if let r = cellRun(s, athlete, si, ri) { out.append(r.time) }
            }
        }
        return out
    }

    func updateSession(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[i]
        change(&s)
        sessions[i] = s
    }

    func deleteSession(_ id: UUID, keepRuns: Bool) {
        if keepRuns {
            runs = runs.map { r in
                var n = r
                if n.sessionId == id {
                    n.sessionId = nil
                    n.series = nil
                    n.rep = nil
                }
                return n
            }
        } else {
            runs.removeAll { $0.sessionId == id }
        }
        sessions.removeAll { $0.id == id }
    }

    // MARK: Fotofinish su file

    private var stripDir: URL {
        let u = docs.appendingPathComponent("strips")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func stripPath(_ id: UUID, _ ext: String) -> URL {
        stripDir.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    func saveStrip(raceId: UUID, jpeg: Data, info: StripInfo) {
        try? jpeg.write(to: stripPath(raceId, "jpg"), options: .atomic)
        if let d = try? JSONEncoder().encode(info) {
            try? d.write(to: stripPath(raceId, "json"), options: .atomic)
        }
        objectWillChange.send()
    }

    func hasStrip(_ raceId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: stripPath(raceId, "jpg").path)
            && FileManager.default.fileExists(atPath: stripPath(raceId, "json").path)
    }

    func loadStrip(_ raceId: UUID) -> (UIImage, StripInfo)? {
        guard let img = UIImage(contentsOfFile: stripPath(raceId, "jpg").path),
              let data = try? Data(contentsOf: stripPath(raceId, "json")),
              let info = try? JSONDecoder().decode(StripInfo.self, from: data) else { return nil }
        return (img, info)
    }

    // MARK: Backup

    func makeBackupURL() -> URL? {
        var strips: [StripBackup] = []
        var seen = Set<UUID>()
        for r in runs {
            guard let rid = r.raceId, !seen.contains(rid) else { continue }
            seen.insert(rid)
            if hasStrip(rid),
               let jpg = try? Data(contentsOf: stripPath(rid, "jpg")),
               let infoData = try? Data(contentsOf: stripPath(rid, "json")),
               let info = try? JSONDecoder().decode(StripInfo.self, from: infoData) {
                strips.append(StripBackup(raceId: rid, info: info, jpeg: jpg.base64EncodedString()))
            }
        }
        let file = BackupFile(version: 2, athletes: athletes, sessions: sessions, runs: runs, strips: strips)
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish-backup-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Unisce un backup ai dati presenti (senza duplicare). Restituisce un messaggio per l'utente.
    func restore(from data: Data) -> String {
        guard let file = try? JSONDecoder().decode(BackupFile.self, from: data) else {
            return "Il file non è un backup valido di FotoFinish."
        }
        var addedRuns = 0
        var addedSessions = 0
        let knownRuns = Set(runs.map { $0.id })
        let knownSessions = Set(sessions.map { $0.id })
        var newRuns = runs
        for r in file.runs where !knownRuns.contains(r.id) {
            newRuns.append(r)
            addedRuns += 1
        }
        var newSessions = sessions
        for s in file.sessions where !knownSessions.contains(s.id) {
            newSessions.append(s)
            addedSessions += 1
        }
        var names = athletes
        for a in file.athletes where !names.contains(a) { names.append(a) }
        for s in file.strips where !hasStrip(s.raceId) {
            if let jpg = Data(base64Encoded: s.jpeg) {
                saveStrip(raceId: s.raceId, jpeg: jpg, info: s.info)
            }
        }
        runs = newRuns.sorted { $0.date > $1.date }
        sessions = newSessions
        athletes = names
        return "Importati \(addedRuns) tempi e \(addedSessions) allenamenti."
    }
}
