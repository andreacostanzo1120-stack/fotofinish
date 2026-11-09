import Foundation
import CoreMedia

/// Orologio unico dell'app: stessa base temporale dei timestamp della fotocamera.
enum HostClock {
    static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

// MARK: - Modalità di gara

enum RaceMode: String, CaseIterable, Identifiable, Codable {
    case soundToRemote
    case flying
    case singlePhone
    case manual

    var id: String { rawValue }

    /// Le modalità selezionabili in Gara
    static var timed: [RaceMode] { [.soundToRemote, .flying, .singlePhone] }

    var title: String {
        switch self {
        case .soundToRemote: return "Sparo"
        case .flying: return "Volata"
        case .singlePhone: return "1 telefono"
        case .manual: return "Manuale"
        }
    }

    var icon: String {
        switch self {
        case .soundToRemote: return "speaker.wave.3.fill"
        case .flying: return "bolt.fill"
        case .singlePhone: return "iphone"
        case .manual: return "pencil"
        }
    }

    var hint: String {
        switch self {
        case .soundToRemote:
            return "Questo telefono dà il via con voce e beep. L’arrivo lo rileva l’altro telefono (Safari) al traguardo."
        case .flying:
            return "Il tempo parte al passaggio davanti a un telefono e si ferma al passaggio davanti all’altro."
        case .singlePhone:
            return "Via sonoro e arrivo sulla fotocamera di questo telefono. Per provare da soli."
        case .manual:
            return "Tempo inserito a mano."
        }
    }

    var usesLocalCamera: Bool { self == .flying || self == .singlePhone }
    var usesRemote: Bool { self == .soundToRemote || self == .flying }
}

// MARK: - Allenamenti e gare

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case training
    case competition

    var id: String { rawValue }
    var title: String { self == .training ? "Allenamento" : "Gara" }
}

/// Programma: ad esempio 2 serie × 3 ripetizioni × 150 m
struct Plan: Codable, Equatable {
    var series = 1
    var reps = 3
    var distance = 100.0
    var recoverySec = 120
    var seriesRecoverySec = 300

    var label: String { "\(series)×\(reps)×\(fmtDist(distance))" }
    var total: Int { series * reps }
}

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title = ""
    var kind: SessionKind = .training
    var athletes: [String] = []
    var plan = Plan()
    var place = ""
    var temperature = ""
    var wind = ""
    var notes = ""

    var displayTitle: String {
        if !title.isEmpty { return title }
        return "\(kind.title) \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Prove

struct Run: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var athlete: String
    var distance: Double
    var mode: RaceMode
    var time: Double
    var uncertaintyMs: Double?
    var raceId: UUID?
    var sessionId: UUID?
    var series: Int?
    var rep: Int?
    var reactionMs: Double?
    var note: String?

    var speedMS: Double { time > 0 ? distance / time : 0 }
    var speedKMH: Double { speedMS * 3.6 }
}

/// Dati del fotofinish di una gara: i tempi di ogni colonna dell'immagine, in secondi dalla partenza.
struct StripInfo: Codable {
    var raceId: UUID
    var colTimes: [Double]
    var source: String
}

struct GateInfo: Identifiable, Equatable {
    var id: Int
    var name: String
    var lastSeen: Double
    var rtt: Double

    static func == (a: GateInfo, b: GateInfo) -> Bool {
        a.id == b.id && a.name == b.name && Int(a.rtt) == Int(b.rtt)
    }
}

// MARK: - Statistiche

struct Stats {
    let n: Int
    let best: Double
    let mean: Double
    let median: Double
    let sd: Double
    let cv: Double
    let first: Double
    let last: Double
    let slope: Double

    init?(_ values: [Double]) {
        guard let firstValue = values.first, let lastValue = values.last, let minValue = values.min() else { return nil }
        let count = values.count
        let m = values.reduce(0, +) / Double(count)
        let sorted = values.sorted()
        let med: Double
        if count % 2 == 1 {
            med = sorted[count / 2]
        } else {
            med = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        var sumSq = 0.0
        for v in values { sumSq += (v - m) * (v - m) }
        let sdev = count > 1 ? (sumSq / Double(count - 1)).squareRoot() : 0
        var sl = 0.0
        if count > 1 {
            let xm = Double(count - 1) / 2
            var num = 0.0
            var den = 0.0
            for (i, v) in values.enumerated() {
                let dx = Double(i) - xm
                num += dx * (v - m)
                den += dx * dx
            }
            sl = den > 0 ? num / den : 0
        }
        self.n = count
        self.best = minValue
        self.mean = m
        self.median = med
        self.sd = sdev
        self.cv = m > 0 ? sdev / m * 100 : 0
        self.first = firstValue
        self.last = lastValue
        self.slope = sl
    }
}

enum Analytics {
    struct Bin: Identifiable {
        let id: Int
        let label: String
        let count: Int
    }

    /// Variazione percentuale tra l'ultima e la prima prova (positivo = più lento)
    static func fatigue(_ t: [Double]) -> Double? {
        guard t.count >= 2, let f = t.first, f > 0, let l = t.last else { return nil }
        return (l - f) / f * 100
    }

    /// Miglior media di n prove consecutive
    static func bestAverage(_ t: [Double], n: Int) -> Double? {
        guard n >= 1, t.count >= n else { return nil }
        var best = Double.greatestFiniteMagnitude
        for i in 0...(t.count - n) {
            let avg = t[i..<(i + n)].reduce(0, +) / Double(n)
            if avg < best { best = avg }
        }
        return best
    }

    /// Percentuale delle altre prove battute dal valore indicato
    static func percentileBeaten(_ t: [Double], value: Double) -> Double? {
        guard t.count >= 2 else { return nil }
        let slower = t.filter { $0 > value }.count
        return Double(slower) / Double(t.count - 1) * 100
    }

    static func histogram(_ t: [Double], bins: Int = 6) -> [Bin] {
        guard let lo = t.min(), let hi = t.max(), t.count >= 2 else { return [] }
        if hi - lo < 0.0001 {
            return [Bin(id: 0, label: String(format: "%.2f", lo), count: t.count)]
        }
        let width = (hi - lo) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for v in t {
            var i = Int((v - lo) / width)
            if i >= bins { i = bins - 1 }
            counts[i] += 1
        }
        return (0..<bins).map { i in
            Bin(id: i, label: String(format: "%.2f", lo + width * Double(i)), count: counts[i])
        }
    }

    /// Proiezione indicativa su un'altra distanza (formula di Riegel)
    static func riegel(time: Double, from d1: Double, to d2: Double) -> Double {
        time * pow(d2 / d1, 1.06)
    }

    /// Recuperi (secondi) tra prove consecutive dello stesso giorno
    static func recoveries(_ runs: [Run]) -> [Double] {
        let timed = runs.filter { $0.mode != .manual }.sorted { $0.date < $1.date }
        guard timed.count > 1 else { return [] }
        var out: [Double] = []
        let cal = Calendar.current
        for i in 1..<timed.count {
            let a = timed[i - 1]
            let b = timed[i]
            guard cal.isDate(a.date, inSameDayAs: b.date) else { continue }
            let rec = b.date.timeIntervalSince(a.date) - b.time
            if rec > 5 && rec < 3600 { out.append(rec) }
        }
        return out
    }
}

// MARK: - Formattazione

func fmtTime(_ t: Double) -> String {
    if t.isNaN || t < 0 { return "0.00" }
    if t >= 60 {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }
    return String(format: "%.2f", t)
}

func fmtDist(_ d: Double) -> String {
    if d == d.rounded() { return String(Int(d)) }
    return String(format: "%.1f", d)
}

func fmtDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

func fmtSigned(_ v: Double, _ digits: Int = 2) -> String {
    String(format: "%+.\(digits)f", v)
}

/// Accetta "11.52", "11,52" e "1:05.30"
func parseTime(_ text: String) -> Double? {
    let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    if s.isEmpty { return nil }
    if s.contains(":") {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
        return m * 60 + sec
    }
    return Double(s)
}
