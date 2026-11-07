import Foundation
import SwiftUI

final class DataStore: ObservableObject {
    @Published var runs: [Run] = [] {
        didSet { saveRuns() }
    }
    @Published var athletes: [String] = ["Atleta 1"] {
        didSet { UserDefaults.standard.set(athletes, forKey: "athletes") }
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runs.json")
    }

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "athletes"), !saved.isEmpty {
            athletes = saved
        }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Run].self, from: data) {
            runs = decoded
        }
    }

    private func saveRuns() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ run: Run) {
        runs.insert(run, at: 0)
    }

    func delete(at offsets: IndexSet) {
        runs.remove(atOffsets: offsets)
    }

    func isPB(_ run: Run) -> Bool {
        let same = runs.filter { $0.athlete == run.athlete && $0.distance == run.distance }
        guard let best = same.map({ $0.time }).min() else { return false }
        return best == run.time
    }
}
