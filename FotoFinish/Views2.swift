import SwiftUI
import Charts

// MARK: - Risultati

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct RunRow: View {
    let run: Run
    let isPB: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.athlete.isEmpty ? "Senza nome" : run.athlete)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmtTime(run.time))
                    .font(.title2.weight(.semibold).monospacedDigit())
                if run.distance > 0 {
                    Text(String(format: "%.1f km/h", run.speedKMH))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if isPB {
                Image(systemName: "star.fill").foregroundColor(.yellow)
            }
        }
    }

    private var subtitle: String {
        let when = run.date.formatted(date: .abbreviated, time: .shortened)
        return "\(fmtDist(run.distance)) m · \(run.mode.title) · \(when)"
    }
}

struct ResultsView: View {
    @EnvironmentObject var store: DataStore
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationStack {
            Group {
                if store.runs.isEmpty {
                    Text("Nessuna prova ancora.\nVai su Gara e tocca VIA.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(store.runs) { r in
                            RunRow(run: r, isPB: store.isPB(r))
                        }
                        .onDelete { offsets in
                            store.delete(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Risultati")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Esporta CSV") { exportCSV() }
                        .disabled(store.runs.isEmpty)
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func num(_ d: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", d).replacingOccurrences(of: ".", with: ",")
    }

    private func exportCSV() {
        var csv = "data;atleta;distanza_m;modalita;tempo_s;velocita_kmh;incertezza_ms\n"
        let formatter = ISO8601DateFormatter()
        for r in store.runs.reversed() {
            let when = formatter.string(from: r.date)
            let unc = r.uncertaintyMs.map { num($0, 1) } ?? ""
            let line = [when, r.athlete, num(r.distance, 1), r.mode.title,
                        num(r.time, 3), num(r.speedKMH, 2), unc].joined(separator: ";")
            csv += line + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish-risultati.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        shareItem = ShareItem(url: url)
    }
}

// MARK: - Statistiche

struct StatRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var store: DataStore
    @State private var athlete = ""
    @State private var distance = 0.0

    private var athletes: [String] {
        Array(Set(store.runs.map { $0.athlete })).sorted()
    }

    private var distances: [Double] {
        Array(Set(store.runs.filter { $0.athlete == athlete }.map { $0.distance })).sorted()
    }

    private var series: [Run] {
        store.runs
            .filter { $0.athlete == athlete && $0.distance == distance }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.runs.isEmpty {
                    Text("Le statistiche compaiono dopo la prima prova.")
                        .foregroundColor(.secondary)
                } else {
                    content
                }
            }
            .navigationTitle("Statistiche")
            .onAppear { fixSelection() }
            .onChange(of: athlete) { _ in
                distance = distances.first ?? 0
            }
        }
    }

    private func fixSelection() {
        if !athletes.contains(athlete) {
            athlete = athletes.first ?? ""
        }
        if !distances.contains(distance) {
            distance = distances.first ?? 0
        }
    }

    private var content: some View {
        let times = series.map { $0.time }
        return List {
            Section {
                Picker("Atleta", selection: $athlete) {
                    ForEach(athletes, id: \.self) { a in
                        Text(a.isEmpty ? "Senza nome" : a).tag(a)
                    }
                }
                Picker("Distanza", selection: $distance) {
                    ForEach(distances, id: \.self) { d in
                        Text("\(fmtDist(d)) m").tag(d)
                    }
                }
            }
            if let st = Stats(times) {
                summary(st)
                Section("Andamento") {
                    chart(times)
                }
            }
        }
    }

    private func summary(_ st: Stats) -> some View {
        Section("Riepilogo") {
            StatRow("Prove", "\(st.n)")
            StatRow("Record personale", fmtTime(st.best) + " s")
            if distance > 0 {
                StatRow("Velocità del record", String(format: "%.1f km/h", distance / st.best * 3.6))
            }
            StatRow("Ultima prova", fmtTime(st.last) + " s")
            StatRow("Ultima rispetto al record", String(format: "%+.2f s", st.last - st.best))
            StatRow("Media", fmtTime(st.mean) + " s")
            StatRow("Mediana", fmtTime(st.median) + " s")
            StatRow("Deviazione standard", String(format: "%.2f s", st.sd))
            StatRow("Costanza (variazione)", String(format: "%.1f %%", st.cv))
            if st.n > 1 {
                StatRow("Tendenza per prova", String(format: "%+.3f s", st.slope))
                StatRow("Ultima rispetto alla prima", String(format: "%+.1f %%", (st.last - st.first) / st.first * 100))
            }
        }
    }

    private func chart(_ times: [Double]) -> some View {
        Chart {
            ForEach(Array(times.enumerated()), id: \.offset) { index, t in
                LineMark(x: .value("Prova", index + 1), y: .value("Tempo (s)", t))
                PointMark(x: .value("Prova", index + 1), y: .value("Tempo (s)", t))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
    }
}

// MARK: - Atleti

struct AthletesView: View {
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var e: RaceEngine
    @State private var newName = ""

    var body: some View {
        List {
            Section("Nuovo atleta") {
                HStack {
                    TextField("Nome", text: $newName)
                    Button("Aggiungi") { add() }
                }
            }
            Section("Atleti") {
                ForEach(store.athletes, id: \.self) { name in
                    Text(name)
                }
                .onDelete { offsets in
                    store.athletes.remove(atOffsets: offsets)
                    if !store.athletes.contains(e.athlete) {
                        e.athlete = store.athletes.first ?? ""
                    }
                }
            }
        }
        .navigationTitle("Atleti")
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !store.athletes.contains(name) else { return }
        store.athletes.append(name)
        e.athlete = name
        newName = ""
    }
}
