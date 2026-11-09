import SwiftUI
import Charts

// MARK: - Condivisione

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

// MARK: - Storico

struct HistoryView: View {
    @State private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Sezione", selection: $page) {
                    Text("Prove").tag(0)
                    Text("Statistiche").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                if page == 0 {
                    RunsListView()
                } else {
                    StatsView()
                }
            }
            .navigationTitle("Storico")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RunRow: View {
    let run: Run
    let isPB: Bool
    let hasStrip: Bool

    private var subtitle: String {
        var parts = ["\(fmtDist(run.distance)) m", run.mode.title,
                     run.date.formatted(date: .omitted, time: .shortened)]
        if let s = run.series, let r = run.rep { parts.append("serie \(s) rip. \(r)") }
        if let ms = run.reactionMs { parts.append("reazione \(Int(ms.rounded())) ms") }
        return parts.joined(separator: " · ")
    }

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
            if hasStrip {
                Image(systemName: "camera.viewfinder").foregroundColor(.secondary)
            }
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
}

struct DayGroup: Identifiable {
    let id: Date
    let runs: [Run]
}

struct RunsListView: View {
    @EnvironmentObject var store: DataStore
    @State private var filter = ""
    @State private var editing: Run?

    private var filtered: [Run] {
        filter.isEmpty ? store.runs : store.runs.filter { $0.athlete == filter }
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in
            DayGroup(id: day, runs: (dict[day] ?? []).sorted { $0.date > $1.date })
        }
    }

    private var athleteNames: [String] {
        Array(Set(store.runs.map { $0.athlete })).sorted()
    }

    var body: some View {
        Group {
            if store.runs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("Nessuna prova ancora.")
                        .font(.headline)
                    Text("Vai su Gara e tocca VIA.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    Section {
                        Picker("Atleta", selection: $filter) {
                            Text("Tutti gli atleti").tag("")
                            ForEach(athleteNames, id: \.self) { n in
                                Text(n.isEmpty ? "Senza nome" : n).tag(n)
                            }
                        }
                    }
                    ForEach(groups) { g in
                        Section(g.id.formatted(date: .complete, time: .omitted)) {
                            ForEach(g.runs) { r in
                                Button {
                                    editing = r
                                } label: {
                                    RunRow(run: r, isPB: store.isPB(r),
                                           hasStrip: r.raceId.map { store.hasStrip($0) } ?? false)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                store.delete(ids: Set(offsets.map { g.runs[$0].id }))
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { r in
            RunEditSheet(run: r)
        }
    }
}

struct RunEditSheet: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State var run: Run
    @State private var timeText = ""
    @State private var distText = ""
    @State private var noteText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Atleta") {
                    Picker("Atleta", selection: $run.athlete) {
                        Text("Senza nome").tag("")
                        ForEach(store.athletes, id: \.self) { n in
                            Text(n).tag(n)
                        }
                    }
                }
                Section("Tempo e distanza") {
                    HStack {
                        Text("Tempo (s)")
                        Spacer()
                        TextField("11.52", text: $timeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Distanza (m)")
                        Spacer()
                        TextField("100", text: $distText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Nota") {
                    TextField("Facoltativa", text: $noteText)
                }
                if let rid = run.raceId, store.hasStrip(rid) {
                    Section {
                        NavigationLink {
                            PhotoFinishView(raceId: rid)
                        } label: {
                            Label("Apri il fotofinish", systemImage: "camera.viewfinder")
                        }
                    }
                }
                Section {
                    Button("Elimina questa prova", role: .destructive) {
                        store.delete(ids: [run.id])
                        dismiss()
                    }
                }
            }
            .navigationTitle("Prova")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }
                }
            }
            .onAppear {
                timeText = String(format: "%.2f", run.time)
                distText = fmtDist(run.distance)
                noteText = run.note ?? ""
            }
        }
    }

    private func save() {
        var r = run
        if let t = parseTime(timeText), t > 0 { r.time = t }
        if let d = Double(distText.replacingOccurrences(of: ",", with: ".")), d > 0 { r.distance = d }
        r.note = noteText.isEmpty ? nil : noteText
        let athleteChanged = r.athlete != (store.runs.first { $0.id == r.id }?.athlete ?? r.athlete)
        store.update(r)
        if athleteChanged { store.assign(r.id, athlete: r.athlete) }
        dismiss()
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
    @State private var avgN = 3
    @State private var share: ShareItem?

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
        Group {
            if store.runs.isEmpty {
                VStack {
                    Spacer()
                    Text("Le statistiche compaiono dopo la prima prova.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                content
            }
        }
        .onAppear { fixSelection() }
        .onChange(of: athlete) { _ in
            distance = distances.first ?? 0
        }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func fixSelection() {
        if !athletes.contains(athlete) { athlete = athletes.first ?? "" }
        if !distances.contains(distance) { distance = distances.first ?? 0 }
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
                summary(st, times: times)
                Section("Andamento") {
                    trendChart(times)
                }
                if times.count >= 3 {
                    Section("Distribuzione dei tempi") {
                        histogramChart(times)
                    }
                }
                fatigueSection()
                comparison()
                projections(st)
                Section {
                    Button {
                        makeReport(st)
                    } label: {
                        Label("Crea report PDF", systemImage: "doc.richtext")
                    }
                }
            }
        }
    }

    private func summary(_ st: Stats, times: [Double]) -> some View {
        let year = Calendar.current.component(.year, from: Date())
        let sb = store.seasonBest(athlete: athlete, distance: distance, year: year)
        return Section("Riepilogo") {
            StatRow("Prove", "\(st.n)")
            StatRow("Record personale", fmtTime(st.best) + " s")
            if let sb = sb {
                StatRow("Miglior tempo \(year)", fmtTime(sb) + " s")
            }
            if distance > 0 {
                StatRow("Velocità del record", String(format: "%.1f km/h", distance / st.best * 3.6))
            }
            StatRow("Ultima prova", fmtTime(st.last) + " s")
            StatRow("Ultima rispetto al record", fmtSigned(st.last - st.best) + " s")
            if let p = Analytics.percentileBeaten(times, value: st.last) {
                StatRow("L’ultima batte", String(format: "%.0f %% delle altre", p))
            }
            StatRow("Media", fmtTime(st.mean) + " s")
            StatRow("Mediana", fmtTime(st.median) + " s")
            StatRow("Deviazione standard", String(format: "%.2f s", st.sd))
            StatRow("Costanza (variazione)", String(format: "%.1f %%", st.cv))
            if st.n > 1 {
                StatRow("Tendenza per prova", fmtSigned(st.slope, 3) + " s")
            }
            if times.count >= avgN, let b = Analytics.bestAverage(times, n: avgN) {
                Stepper(value: $avgN, in: 2...6) {
                    HStack {
                        Text("Miglior media di \(avgN)")
                        Spacer()
                        Text(fmtTime(b) + " s").foregroundColor(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func trendChart(_ times: [Double]) -> some View {
        Chart {
            ForEach(Array(times.enumerated()), id: \.offset) { index, t in
                LineMark(x: .value("Prova", index + 1), y: .value("Tempo (s)", t))
                PointMark(x: .value("Prova", index + 1), y: .value("Tempo (s)", t))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
    }

    private func histogramChart(_ times: [Double]) -> some View {
        let bins = Analytics.histogram(times)
        return Chart {
            ForEach(bins) { b in
                BarMark(x: .value("Tempo", b.label), y: .value("Prove", b.count))
            }
        }
        .frame(height: 160)
    }

    private func fatigueSection() -> some View {
        let all = store.runs.filter { $0.athlete == athlete && $0.distance == distance }
        let cal = Calendar.current
        let byDay = Dictionary(grouping: all) { cal.startOfDay(for: $0.date) }
        var fatigues: [Double] = []
        for (_, list) in byDay {
            let t = list.sorted { $0.date < $1.date }.map { $0.time }
            if let f = Analytics.fatigue(t) { fatigues.append(f) }
        }
        let rec = Analytics.recoveries(store.runs.filter { $0.athlete == athlete })
        return Section("Fatica e recuperi") {
            if fatigues.isEmpty {
                Text("Servono almeno due prove nello stesso giorno.")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else {
                let avg = fatigues.reduce(0, +) / Double(fatigues.count)
                StatRow("Calo medio (ultima vs prima)", String(format: "%+.1f %%", avg))
            }
            if rec.isEmpty {
                Text("Nessun recupero misurabile.")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else {
                let avgRec = rec.reduce(0, +) / Double(rec.count)
                StatRow("Recupero medio tra le prove", fmtDuration(avgRec))
            }
        }
    }

    private func comparison() -> some View {
        var unsorted: [(String, Double)] = []
        for a in athletes {
            let best = store.runs.filter { $0.athlete == a && $0.distance == distance }.map { $0.time }.min()
            if let b = best { unsorted.append((a, b)) }
        }
        let rows = unsorted.sorted { $0.1 < $1.1 }
        return Section("Atleti a confronto sui \(fmtDist(distance)) m") {
            if rows.count < 2 {
                Text("Serve almeno un altro atleta con prove su questa distanza.")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else {
                let lead = rows[0].1
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack {
                        Text("\(idx + 1)° \(row.0.isEmpty ? "Senza nome" : row.0)")
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(fmtTime(row.1) + " s").monospacedDigit()
                            if idx > 0 {
                                let dt = row.1 - lead
                                Text(String(format: "+%.2f s · %.1f m", dt, dt * (distance / row.1)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func projections(_ st: Stats) -> some View {
        Section("Proiezioni indicative") {
            if st.best >= 90 {
                ForEach([800.0, 1000.0, 1500.0, 3000.0, 5000.0].filter { $0 != distance }, id: \.self) { d in
                    StatRow("\(fmtDist(d)) m", fmtDuration(Analytics.riegel(time: st.best, from: distance, to: d)))
                }
                Text("Formula di Riegel: stima approssimativa per mezzofondo e fondo.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Disponibili per prove di mezzofondo e fondo (record oltre 1:30). Per gli sprint la formula non è affidabile.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func makeReport(_ st: Stats) {
        if let url = ReportBuilder.athleteReport(athlete: athlete, distance: distance, runs: series, stats: st) {
            share = ShareItem(url: url)
        }
    }
}
