import SwiftUI
import Charts

// MARK: - Elenco

struct SessionsView: View {
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var e: RaceEngine
    @State private var path: [UUID] = []
    @State private var showNew = false

    private var sorted: [Session] {
        store.sessions.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if sorted.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Qui annoti il lavoro del giorno.")
                                .font(.headline)
                            Text("Esempio: tre atleti fanno 2×3×150, cioè 2 serie da 3 ripetizioni di 150 metri. L’app registra i tempi di ognuno e li confronta.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button {
                                showNew = true
                            } label: {
                                Label("Nuovo allenamento", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                }
                ForEach(sorted) { s in
                    NavigationLink(value: s.id) {
                        SessionRow(session: s, active: e.activeSessionId == s.id)
                    }
                }
            }
            .navigationTitle("Allenamento")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionId: id)
            }
            .sheet(isPresented: $showNew) {
                NewSessionSheet { id in path.append(id) }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.displayTitle).font(.headline)
                if active {
                    Text("In corso")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
            Text("\(session.plan.label) · \(session.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if !session.athletes.isEmpty {
                Text(session.athletes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Nuovo allenamento

struct NewSessionSheet: View {
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var e: RaceEngine
    @Environment(\.dismiss) private var dismiss
    @State private var session = Session()
    @State private var distText = "100"
    @State private var newAthlete = ""
    let onCreate: (UUID) -> Void

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { session.athletes.contains(name) },
            set: { on in
                if on {
                    if !session.athletes.contains(name) { session.athletes.append(name) }
                } else {
                    session.athletes.removeAll { $0 == name }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if let last = store.sessions.first {
                    Section {
                        Button {
                            session.athletes = last.athletes
                            session.plan = last.plan
                            session.kind = last.kind
                            distText = fmtDist(last.plan.distance)
                        } label: {
                            Label("Copia l’ultimo: \(last.plan.label)", systemImage: "doc.on.doc")
                        }
                    }
                }

                Section("Tipo") {
                    Picker("Tipo", selection: $session.kind) {
                        ForEach(SessionKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Titolo (facoltativo)", text: $session.title)
                    DatePicker("Data", selection: $session.date)
                }

                Section("Atleti") {
                    ForEach(store.athletes, id: \.self) { name in
                        Toggle(name, isOn: binding(for: name))
                    }
                    HStack {
                        TextField("Nuovo atleta", text: $newAthlete)
                        Button("Aggiungi") {
                            let n = newAthlete.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            if !store.athletes.contains(n) { store.athletes.append(n) }
                            if !session.athletes.contains(n) { session.athletes.append(n) }
                            newAthlete = ""
                        }
                    }
                }

                Section("Programma") {
                    Stepper("Serie: \(session.plan.series)", value: $session.plan.series, in: 1...10)
                    Stepper("Ripetizioni per serie: \(session.plan.reps)", value: $session.plan.reps, in: 1...20)
                    HStack {
                        Text("Distanza (m)")
                        Spacer()
                        TextField("100", text: $distText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach([60.0, 100.0, 150.0, 200.0, 300.0, 400.0], id: \.self) { d in
                                Chip(title: fmtDist(d), selected: distText == fmtDist(d)) {
                                    distText = fmtDist(d)
                                }
                            }
                        }
                    }
                    Stepper("Recupero tra ripetizioni: \(fmtDuration(Double(session.plan.recoverySec)))",
                            value: $session.plan.recoverySec, in: 0...900, step: 15)
                    Stepper("Recupero tra serie: \(fmtDuration(Double(session.plan.seriesRecoverySec)))",
                            value: $session.plan.seriesRecoverySec, in: 0...1800, step: 30)
                }

                Section("Dettagli (facoltativi)") {
                    TextField("Luogo", text: $session.place)
                    TextField("Temperatura", text: $session.temperature)
                    TextField("Vento", text: $session.wind)
                    TextField("Note", text: $session.notes)
                }
            }
            .navigationTitle("Nuovo allenamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") { create() }
                        .disabled(session.athletes.isEmpty)
                }
            }
        }
    }

    private func create() {
        var s = session
        s.plan.distance = Double(distText.replacingOccurrences(of: ",", with: ".")) ?? 100
        store.sessions.insert(s, at: 0)
        e.startSession(s.id)
        onCreate(s.id)
        dismiss()
    }
}

// MARK: - Dettaglio

struct CellRef: Identifiable {
    let id = UUID()
    let athlete: String
    let series: Int
    let rep: Int
}

struct SessionDetailView: View {
    let sessionId: UUID
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var e: RaceEngine
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var cellRef: CellRef?
    @State private var share: ShareItem?
    @State private var showAthletes = false
    @State private var confirmDelete = false

    private var session: Session? {
        store.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        Group {
            if let s = session {
                content(s)
            } else {
                Text("Allenamento non trovato").foregroundColor(.secondary)
            }
        }
        .navigationTitle(session?.displayTitle ?? "Allenamento")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showAthletes = true } label: {
                        Label("Atleti", systemImage: "person.2")
                    }
                    Button { makeReport() } label: {
                        Label("Report PDF", systemImage: "doc.richtext")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $cellRef) { ref in
            if let s = session {
                CellEditSheet(session: s, cell: ref)
            }
        }
        .sheet(isPresented: $showAthletes) {
            SessionAthletesSheet(sessionId: sessionId)
        }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Elimina allenamento", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina allenamento e tempi", role: .destructive) {
                if e.activeSessionId == sessionId { e.activeSessionId = nil }
                store.deleteSession(sessionId, keepRuns: false)
                dismiss()
            }
            Button("Elimina solo l’allenamento, tieni i tempi") {
                if e.activeSessionId == sessionId { e.activeSessionId = nil }
                store.deleteSession(sessionId, keepRuns: true)
                dismiss()
            }
            Button("Annulla", role: .cancel) {}
        }
    }

    private func content(_ s: Session) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.plan.label).font(.title2.bold())
                        Text(s.date.formatted(date: .complete, time: .shortened))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        e.startSession(s.id)
                        e.selectedTab = 0
                    } label: {
                        Label("Cronometra", systemImage: "stopwatch")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Picker("Sezione", selection: $tab) {
                    Text("Tempi").tag(0)
                    Text("Confronto").tag(1)
                    Text("Info").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == 0 {
                        TimesGrid(session: s) { ref in cellRef = ref }
                    } else if tab == 1 {
                        CompareView(session: s)
                    } else {
                        InfoView(session: s)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }

    private func makeReport() {
        guard let s = session else { return }
        if let url = ReportBuilder.sessionReport(session: s, store: store) {
            share = ShareItem(url: url)
        }
    }
}

// MARK: - Griglia dei tempi

struct TimesGrid: View {
    let session: Session
    let onSelect: (CellRef) -> Void
    @EnvironmentObject var store: DataStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.athletes.isEmpty {
                Text("Aggiungi gli atleti dal menu in alto a destra.")
                    .foregroundColor(.secondary)
            } else {
                Text("Tocca una casella per scrivere o correggere un tempo. L’arancione indica la prossima da fare.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(1...max(1, session.plan.series), id: \.self) { s in
                seriesBlock(s)
            }
            totals
        }
    }

    private func seriesBlock(_ s: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Serie \(s)").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("").frame(width: 84)
                        ForEach(1...max(1, session.plan.reps), id: \.self) { r in
                            Text("R\(r)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 64)
                        }
                        Text("Media")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 64)
                    }
                    ForEach(session.athletes, id: \.self) { a in
                        athleteRow(a, s)
                    }
                }
            }
        }
    }

    private func athleteRow(_ a: String, _ s: Int) -> some View {
        let reps = max(1, session.plan.reps)
        var times: [Double] = []
        for r in 1...reps {
            if let run = store.cellRun(session, a, s, r) { times.append(run.time) }
        }
        let next = store.cellFor(athlete: a, session: session, excluding: nil)
        let avgText = times.isEmpty ? "—" : fmtTime(times.reduce(0, +) / Double(times.count))
        return HStack(spacing: 6) {
            Text(a)
                .font(.subheadline)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            ForEach(1...reps, id: \.self) { r in
                cell(a, s, r, next)
            }
            Text(avgText)
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 64)
        }
    }

    private func columnBest(_ s: Int, _ r: Int) -> Double? {
        session.athletes.compactMap { store.cellRun(session, $0, s, r)?.time }.min()
    }

    private func cell(_ a: String, _ s: Int, _ r: Int, _ next: (Int, Int)?) -> some View {
        let run = store.cellRun(session, a, s, r)
        var isNext = false
        if let n = next { isNext = (n.0 == s && n.1 == r) }
        let isBest = run != nil && run?.time == columnBest(s, r)
        let text = run.map { fmtTime($0.time) } ?? "—"
        return Button {
            onSelect(CellRef(athlete: a, series: s, rep: r))
        } label: {
            Text(text)
                .font(.subheadline.monospacedDigit().weight(isBest ? .bold : .regular))
                .frame(width: 64, height: 36)
                .background(isBest ? Color.green.opacity(0.25) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isNext ? Color.orange : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Riepilogo").font(.headline)
            ForEach(session.athletes, id: \.self) { a in
                let t = store.sessionTimes(session, athlete: a)
                HStack {
                    Text(a)
                    Spacer()
                    if t.isEmpty {
                        Text("—").foregroundColor(.secondary)
                    } else {
                        let avg = t.reduce(0, +) / Double(t.count)
                        Text("migliore \(fmtTime(t.min() ?? 0)) · media \(fmtTime(avg))")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct CellEditSheet: View {
    let session: Session
    let cell: CellRef
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var existing: Run? {
        store.cellRun(session, cell.athlete, cell.series, cell.rep)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("\(cell.athlete) · serie \(cell.series), ripetizione \(cell.rep)") {
                    TextField("Tempo, ad esempio 18.42", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                }
                if existing != nil {
                    Section {
                        Button("Cancella questo tempo", role: .destructive) {
                            store.setCell(session, athlete: cell.athlete, series: cell.series, rep: cell.rep, time: nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Tempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if let t = parseTime(text), t > 0 {
                            store.setCell(session, athlete: cell.athlete, series: cell.series, rep: cell.rep, time: t)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let r = existing { text = String(format: "%.2f", r.time) }
            }
        }
        .presentationDetents([.medium])
    }
}

struct SessionAthletesSheet: View {
    let sessionId: UUID
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    private var current: [String] {
        store.sessions.first { $0.id == sessionId }?.athletes ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Atleti dell’allenamento") {
                    ForEach(store.athletes, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { current.contains(name) },
                            set: { on in
                                store.updateSession(sessionId) { s in
                                    if on {
                                        if !s.athletes.contains(name) { s.athletes.append(name) }
                                    } else {
                                        s.athletes.removeAll { $0 == name }
                                    }
                                }
                            }
                        ))
                    }
                }
                Section("Aggiungi un nuovo atleta") {
                    HStack {
                        TextField("Nome", text: $newName)
                        Button("Aggiungi") {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            if !store.athletes.contains(n) { store.athletes.append(n) }
                            store.updateSession(sessionId) { s in
                                if !s.athletes.contains(n) { s.athletes.append(n) }
                            }
                            newName = ""
                        }
                    }
                }
            }
            .navigationTitle("Atleti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Confronto

struct CompareView: View {
    let session: Session
    @EnvironmentObject var store: DataStore

    struct Row: Identifiable {
        let id = UUID()
        let name: String
        let times: [Double]
        let stats: Stats?
    }

    struct Point: Identifiable {
        let id = UUID()
        let athlete: String
        let index: Int
        let time: Double
    }

    private var rows: [Row] {
        session.athletes.map { a -> Row in
            let t = store.sessionTimes(session, athlete: a)
            return Row(name: a, times: t, stats: Stats(t))
        }
    }

    private var points: [Point] {
        var out: [Point] = []
        for a in session.athletes {
            for s in 1...max(1, session.plan.series) {
                for r in 1...max(1, session.plan.reps) {
                    if let run = store.cellRun(session, a, s, r) {
                        out.append(Point(athlete: a, index: (s - 1) * session.plan.reps + r, time: run.time))
                    }
                }
            }
        }
        return out
    }

    private var previous: Session? {
        store.sessions
            .filter { $0.id != session.id && $0.date < session.date && $0.plan.distance == session.plan.distance }
            .sorted { $0.date > $1.date }
            .first
    }

    var body: some View {
        let data = rows
        VStack(alignment: .leading, spacing: 20) {
            if points.isEmpty {
                Text("Registra qualche tempo per vedere il confronto.")
                    .foregroundColor(.secondary)
            } else {
                table(data)
                ranking(data)
                chart
                recoveries(data)
                if let p = previous { previousComparison(p, data) }
            }
        }
    }

    private func table(_ data: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Atleti a confronto").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Atleta").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Text("Migliore").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Text("Media").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Text("Calo").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Text("Costanza").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                }
                Divider()
                ForEach(data) { r in
                    GridRow {
                        Text(r.name).lineLimit(1)
                        Text(r.stats.map { fmtTime($0.best) } ?? "—")
                        Text(r.stats.map { fmtTime($0.mean) } ?? "—")
                        Text(Analytics.fatigue(r.times).map { String(format: "%+.1f%%", $0) } ?? "—")
                        Text(r.stats.map { String(format: "%.1f%%", $0.cv) } ?? "—")
                    }
                }
            }
            .font(.subheadline.monospacedDigit())
            Text("Calo: ultima ripetizione rispetto alla prima (positivo = più lento). Costanza: più basso è, più regolare.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func ranking(_ data: [Row]) -> some View {
        let withMean = data.compactMap { r -> (String, Double)? in
            guard let st = r.stats else { return nil }
            return (r.name, st.mean)
        }.sorted { $0.1 < $1.1 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Classifica per tempo medio").font(.headline)
            if let lead = withMean.first?.1 {
                ForEach(Array(withMean.enumerated()), id: \.offset) { idx, item in
                    HStack {
                        Text("\(idx + 1)° \(item.0)")
                        Spacer()
                        Text(fmtTime(item.1)).monospacedDigit()
                        Text(idx == 0 ? "" : String(format: "+%.2f s", item.1 - lead))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Andamento delle ripetizioni").font(.headline)
            Chart(points) { p in
                LineMark(x: .value("Ripetizione", p.index), y: .value("Tempo (s)", p.time))
                    .foregroundStyle(by: .value("Atleta", p.athlete))
                PointMark(x: .value("Ripetizione", p.index), y: .value("Tempo (s)", p.time))
                    .foregroundStyle(by: .value("Atleta", p.athlete))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 220)
        }
    }

    private func recoveries(_ data: [Row]) -> some View {
        var lines: [(String, Double)] = []
        for a in session.athletes {
            let runs = store.runs.filter { $0.sessionId == session.id && $0.athlete == a }
            let rec = Analytics.recoveries(runs)
            if !rec.isEmpty { lines.append((a, rec.reduce(0, +) / Double(rec.count))) }
        }
        return Group {
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recupero medio tra le ripetizioni").font(.headline)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.0)
                            Spacer()
                            Text(fmtDuration(item.1)).monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    Text("Programmato: \(fmtDuration(Double(session.plan.recoverySec))) tra ripetizioni.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func previousComparison(_ p: Session, _ data: [Row]) -> some View {
        var lines: [(String, Double, Double)] = []
        for r in data {
            guard let st = r.stats else { continue }
            let before = store.sessionTimes(p, athlete: r.name)
            guard let old = Stats(before) else { continue }
            lines.append((r.name, st.mean, old.mean))
        }
        return Group {
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rispetto al \(p.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.headline)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.0)
                            Spacer()
                            Text("media \(fmtTime(item.1)) (\(fmtSigned(item.1 - item.2)) s)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(item.1 <= item.2 ? .green : .red)
                        }
                    }
                    Text("Stessa distanza, confronto con l’allenamento precedente. Verde = più veloce.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Info

struct InfoView: View {
    let session: Session
    @EnvironmentObject var store: DataStore

    private func bind(_ keyPath: WritableKeyPath<Session, String>) -> Binding<String> {
        Binding(
            get: { session[keyPath: keyPath] },
            set: { v in store.updateSession(session.id) { $0[keyPath: keyPath] = v } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                labeled("Titolo", TextField("Titolo", text: bind(\.title)))
                labeled("Luogo", TextField("Luogo", text: bind(\.place)))
                labeled("Temperatura", TextField("Temperatura", text: bind(\.temperature)))
                labeled("Vento", TextField("Vento", text: bind(\.wind)))
                labeled("Note", TextField("Note", text: bind(\.notes), axis: .vertical))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Programma").font(.subheadline.weight(.semibold))
                Stepper("Serie: \(session.plan.series)", value: Binding(
                    get: { session.plan.series },
                    set: { v in store.updateSession(session.id) { $0.plan.series = v } }
                ), in: 1...10)
                Stepper("Ripetizioni per serie: \(session.plan.reps)", value: Binding(
                    get: { session.plan.reps },
                    set: { v in store.updateSession(session.id) { $0.plan.reps = v } }
                ), in: 1...20)
                Text("Se cambi serie o ripetizioni dopo aver registrato dei tempi, quelli fuori programma restano salvati ma non si vedono nella griglia.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func labeled<F: View>(_ title: String, _ field: F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            field.textFieldStyle(.roundedBorder)
        }
    }
}
