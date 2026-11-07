import Foundation
import CoreMedia

/// Orologio unico dell'app: stessa base temporale dei timestamp della fotocamera.
enum HostClock {
    static func now() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

enum RaceMode: String, CaseIterable, Identifiable, Codable {
    case soundToRemote
    case flying
    case singlePhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soundToRemote: return "Sparo"
        case .flying: return "Volata"
        case .singlePhone: return "1 telefono"
        }
    }

    var hint: String {
        switch self {
        case .soundToRemote:
            return "Questo telefono dà il via con voce e beep. L’arrivo lo rileva l’altro telefono (Safari) quando qualcuno passa davanti alla sua fotocamera."
        case .flying:
            return "Il tempo parte quando qualcuno passa davanti alla fotocamera di questo telefono e si ferma al passaggio davanti all’altro telefono."
        case .singlePhone:
            return "Via sonoro e arrivo sulla fotocamera di questo telefono. Utile per provare l’app da soli."
        }
    }

    var usesLocalCamera: Bool { self != .soundToRemote }
    var usesRemote: Bool { self != .singlePhone }
}

struct Run: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var athlete: String
    var distance: Double
    var mode: RaceMode
    var time: Double
    var uncertaintyMs: Double?

    var speedMS: Double { time > 0 ? distance / time : 0 }
    var speedKMH: Double { speedMS * 3.6 }
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
