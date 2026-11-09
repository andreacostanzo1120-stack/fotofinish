import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Elementi comuni

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundColor(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MainButton: View {
    @EnvironmentObject var e: RaceEngine

    private var isBusy: Bool {
        e.phase == .armed || e.phase == .running
    }

    var body: some View {
        let label = isBusy ? "ANNULLA" : (e.mode == .flying ? "ARMA" : "VIA")
        Button {
            if isBusy { e.cancel() } else { e.startRun() }
        } label: {
            Text(label)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(isBusy ? .red : .green)
    }
}

struct TimeBlock: View {
    @EnvironmentObject var e: RaceEngine

    private var statusColor: Color {
        switch e.phase {
        case .idle: return .secondary
        case .armed: return .orange
        case .running: return .red
        case .finished: return .green
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.03)) { _ in
                Text(fmtTime(e.displayTime()))
                    .font(.system(size: 80, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            Text(e.statusText)
                .font(.title3.weight(.semibold))
                .foregroundColor(statusColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AddAthleteSheet: View {
    @EnvironmentObject var store: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onAdded: (String) -> Void

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome dell’atleta", text: $name)
            }
            .navigationTitle("Nuovo atleta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi") {
                        if !store.athletes.contains(trimmed) { store.athletes.append(trimmed) }
                        onAdded(trimmed)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Gara

struct RaceView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var settings: AppSettings
    @State private var showConnect = false
    @State private var showAddAthlete = false

    private var isBusy: Bool {
        e.phase == .armed || e.phase == .running
    }

    var body: some View {
        NavigationStack {
            Group {
                if settings.fieldMode {
                    FieldModeView()
                } else {
                    normal
                }
            }
            .navigationTitle("Gara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(settings.fieldMode ? .hidden : .visible, for: .navigationBar)
            .toolbar(settings.fieldMode ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        settings.fieldMode = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
        }
        .statusBar(hidden: settings.fieldMode)
        .sheet(isPresented: $showConnect) {
            NavigationStack { ConnectView(showsClose: true) }
        }
        .sheet(isPresented: $showAddAthlete) {
            AddAthleteSheet { name in
                if !e.runners.contains(name) { e.toggleRunner(name) }
            }
        }
    }

    private var normal: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let s = e.activeSession {
                    SessionBanner(session: s)
                }
                TimeBlock()
                if e.mode.usesRemote { gateStatus }
                MainButton()
                if e.phase == .finished {
                    RaceResultCard()
                }
                modePicker
                runnersRow
                if e.activeSession == nil {
                    distanceRow
                } else {
                    Text("Distanza dal programma: \(fmtDist(e.distance)) m")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if e.needsCamera {
                    CameraBlock(camera: e.camera, sensitivity: $e.cameraSensitivity)
                }
            }
            .padding()
        }
    }

    private var gateStatus: some View {
        Button {
            showConnect = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(e.gates.isEmpty ? Color.orange : Color.green)
                    .frame(width: 12, height: 12)
                Text(e.gates.isEmpty ? "Secondo telefono non collegato: tocca per collegarlo" : "Secondo telefono collegato")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RaceMode.timed) { m in
                    Button {
                        e.mode = m
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: m.icon).font(.title3)
                            Text(m.title).font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(e.mode == m ? Color.accentColor : Color(.secondarySystemBackground))
                        .foregroundColor(e.mode == m ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(e.mode.hint)
                .font(.footnote)
                .foregroundColor(.secondary)
            if e.mode == .flying {
                Toggle("Arrivo sul telefono principale", isOn: $e.reversed)
                    .font(.subheadline)
                Text("Attivalo se vuoi il fotofinish a 240 fps: il telefono principale va al traguardo, l’altro alla partenza.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if e.mode == .soundToRemote {
                Toggle("Misura la reazione allo start", isOn: $e.measureReaction)
                    .font(.subheadline)
                Text("Metti questo telefono davanti ai blocchi: rileva il primo movimento dopo il beep.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(isBusy)
    }

    private var athleteOptions: [String] {
        if let s = e.activeSession { return s.athletes }
        return store.athletes
    }

    private var runnersRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chi corre").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(athleteOptions, id: \.self) { name in
                        Chip(title: name, selected: e.runners.contains(name)) {
                            e.toggleRunner(name)
                        }
                    }
                    Chip(title: "+ Nuovo", selected: false) { showAddAthlete = true }
                }
            }
            if e.runners.count > 1 {
                Text("Più atleti: dopo l’arrivo tocca il tempo e scegli chi è.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isBusy)
    }

    private var distanceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Distanza").font(.subheadline.weight(.semibold))
                TextField("m", value: $e.distance, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("m")
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([30.0, 60.0, 100.0, 150.0, 200.0, 300.0, 400.0], id: \.self) { d in
                        Chip(title: fmtDist(d), selected: e.distance == d) { e.distance = d }
                    }
                }
            }
        }
        .disabled(isBusy)
    }
}

struct FieldModeView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button("Esci dalla modalità campo") { settings.fieldMode = false }
                    .buttonStyle(.bordered)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.03)) { _ in
                Text(fmtTime(e.displayTime()))
                    .font(.system(size: 130, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
            }
            Text(e.statusText)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
            MainButton()
        }
        .padding()
    }
}

// MARK: - Banner dell'allenamento

struct SessionBanner: View {
    let session: Session
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore

    private var nextText: String {
        let names = e.runners.isEmpty ? session.athletes : e.runners
        let parts = names.map { n -> String in
            if let c = store.cellFor(athlete: n, session: session, excluding: nil) {
                return "\(n): serie \(c.0), rip. \(c.1)"
            }
            return "\(n): completato"
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                Text("\(session.displayTitle) · \(session.plan.label)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Esci") { e.activeSessionId = nil }
                    .font(.footnote)
            }
            Text(nextText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Risultato della gara

struct RaceResultCard: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore

    var body: some View {
        let runs = e.lastRaceRuns
        VStack(alignment: .leading, spacing: 12) {
            Text(runs.count > 1 ? "Arrivi" : "Risultato").font(.headline)
            ForEach(Array(runs.enumerated()), id: \.element.id) { idx, r in
                ResultRow(run: r, place: idx + 1, leader: runs.first)
            }
            if let ms = e.reactionMs {
                HStack {
                    Image(systemName: "timer")
                    Text("Reazione: \(Int(ms.rounded())) ms")
                    if ms < 100 {
                        Text("Partenza anticipata").foregroundColor(.red).font(.footnote.weight(.semibold))
                    }
                    Spacer()
                }
                .font(.subheadline)
            }
            if let rid = e.lastRaceId {
                if store.hasStrip(rid) {
                    NavigationLink {
                        PhotoFinishView(raceId: rid)
                    } label: {
                        Label("Apri il fotofinish", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if e.stripPending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Fotofinish in preparazione…").font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ResultRow: View {
    let run: Run
    let place: Int
    let leader: Run?
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore

    private var options: [String] {
        if let s = e.activeSession { return s.athletes }
        return store.athletes
    }

    private var gapText: String? {
        guard let l = leader, l.id != run.id, run.distance > 0, run.time > 0 else { return nil }
        let dt = run.time - l.time
        let meters = dt * (run.distance / run.time)
        return String(format: "+%.2f s · %.1f m", dt, meters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(place)°").font(.headline).frame(width: 30, alignment: .leading)
                Text(fmtTime(run.time))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer()
                Menu {
                    ForEach(options, id: \.self) { name in
                        Button(name) { store.assign(run.id, athlete: name) }
                    }
                    Button("Senza nome") { store.assign(run.id, athlete: "") }
                } label: {
                    Label(run.athlete.isEmpty ? "Assegna atleta" : run.athlete, systemImage: "person.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(run.athlete.isEmpty ? Color.orange.opacity(0.25) : Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 12) {
                if run.distance > 0 {
                    Text(String(format: "%.1f km/h", run.speedKMH))
                }
                if let g = gapText { Text(g) }
                if let u = run.uncertaintyMs { Text("± \(Int(u.rounded())) ms") }
                if let s = run.series, let r = run.rep { Text("serie \(s), rip. \(r)") }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - Fotocamera

struct CameraBlock: View {
    @ObservedObject var camera: CameraGate
    @Binding var sensitivity: Double

    private var threshold: Double { 0.5 - 0.45 * sensitivity }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fotocamera di questo telefono").font(.subheadline.weight(.semibold))
            ZStack {
                CameraPreview(session: camera.session, running: camera.running)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2)
            }
            .frame(height: 230)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if camera.permissionDenied {
                Text("Permesso fotocamera negato. Abilitalo in Impostazioni > FotoFinish.")
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let active = camera.lastRatio > threshold
                HStack {
                    ProgressView(value: min(1, camera.lastRatio / 0.5))
                        .tint(active ? .red : .green)
                    Text("\(Int(camera.fps)) fps")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Sensibilità").font(.footnote)
                Slider(value: $sensitivity, in: 0...1)
            }
            Text("Allinea la linea arancione con il traguardo. Tieni il telefono fermo, meglio con un treppiede.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Collegamento del secondo telefono

func makeQR(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let context = CIContext()
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
}

struct ConnectView: View {
    var showsClose = false
    @EnvironmentObject var e: RaceEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Come collegare il secondo telefono") {
                Text("1. Su questo iPhone attiva Hotspot personale (Impostazioni).")
                Text("2. Sul secondo telefono collegati a quel Wi‑Fi.")
                Text("3. Inquadra il QR con la Fotocamera del secondo telefono e apri il link in Safari.")
                Text("4. Se Safari avvisa del certificato: Mostra dettagli, poi “visita questo sito web”. Succede una volta sola.")
                Text("5. Tocca “Attiva fotocamera” e consenti l’accesso.")
            }
            .font(.subheadline)

            Section("Indirizzo") {
                if e.urls.isEmpty {
                    Text("Nessuna rete trovata. Attiva l’hotspot personale oppure collegati a un Wi‑Fi.")
                        .foregroundColor(.secondary)
                }
                ForEach(e.urls, id: \.self) { u in
                    VStack(alignment: .center, spacing: 8) {
                        Text(u)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if let img = makeQR(u) {
                            Image(uiImage: img)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Section("Telefoni collegati") {
                if e.gates.isEmpty {
                    Text("Nessuno").foregroundColor(.secondary)
                }
                ForEach(e.gates) { g in
                    HStack {
                        Image(systemName: "iphone")
                        Text("Telefono \(g.id)")
                        Spacer()
                        if g.rtt > 0 {
                            Text("± \(Int(g.rtt / 2)) ms")
                                .foregroundColor(.secondary)
                                .font(.footnote)
                        }
                    }
                }
            }

            Section("Server") {
                Text(e.serverMessage).font(.footnote)
                Button("Riavvia server") { e.restartServer() }
            }
        }
        .navigationTitle("Secondo telefono")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
