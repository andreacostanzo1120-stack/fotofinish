import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Gara

struct RaceView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore

    private var isBusy: Bool {
        e.phase == .armed || e.phase == .running
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    modePicker
                    setup
                    timeBlock
                    if e.mode.usesRemote { gateStatus }
                    if e.mode.usesLocalCamera {
                        CameraBlock(camera: e.camera, sensitivity: $e.cameraSensitivity)
                    }
                    mainButton
                    if let r = e.lastRun { ResultCard(run: r) }
                }
                .padding()
            }
            .navigationTitle("Gara")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: e.mode) { _ in e.refreshCameraUsage() }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Modalità", selection: $e.mode) {
                ForEach(RaceMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
            Text(e.mode.hint)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var setup: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Atleta", selection: $e.athlete) {
                    ForEach(store.athletes, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                NavigationLink("Gestisci atleti") { AthletesView() }
                    .font(.footnote)
            }
            HStack {
                Text("Distanza")
                TextField("m", value: $e.distance, format: .number)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("m")
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach([30.0, 60.0, 100.0, 200.0, 400.0], id: \.self) { d in
                    Button(fmtDist(d)) { e.distance = d }
                        .buttonStyle(.bordered)
                }
            }
        }
        .disabled(isBusy)
    }

    private var statusColor: Color {
        switch e.phase {
        case .idle: return .secondary
        case .armed: return .orange
        case .running: return .red
        case .finished: return .green
        }
    }

    private var timeBlock: some View {
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
            if let u = e.lastRun?.uncertaintyMs {
                Text("± \(Int(u.rounded())) ms circa (sincronizzazione)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var gateStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(e.gates.isEmpty ? Color.orange : Color.green)
                .frame(width: 12, height: 12)
            Text(e.gates.isEmpty ? "Nessun telefono collegato (vai su Collega)" : "Telefono collegato: \(e.gates.count)")
                .font(.subheadline)
            Spacer()
        }
    }

    private var mainButton: some View {
        let label = isBusy ? "ANNULLA" : (e.mode == .flying ? "ARMA" : "VIA")
        return Button {
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

struct CameraBlock: View {
    @ObservedObject var camera: CameraGate
    @Binding var sensitivity: Double

    private var threshold: Double { 0.5 - 0.45 * sensitivity }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text("Allinea la linea arancione con il traguardo. Tieni il telefono fermo (meglio con un treppiede).")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct ResultCard: View {
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ultima prova").font(.headline)
            row("Tempo", fmtTime(run.time) + " s")
            if run.distance > 0 {
                row("Velocità media", String(format: "%.2f m/s · %.1f km/h", run.speedMS, run.speedKMH))
                if run.distance >= 400 {
                    let pace = run.time / run.distance * 1000
                    row("Passo", String(format: "%d:%02d /km", Int(pace) / 60, Int(pace) % 60))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).foregroundColor(.secondary)
            Spacer()
            Text(b).monospacedDigit()
        }
    }
}

// MARK: - Collega

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
    @EnvironmentObject var e: RaceEngine

    var body: some View {
        NavigationStack {
            List {
                Section("Come collegare il secondo telefono") {
                    Text("1. Su questo iPhone attiva Hotspot personale (Impostazioni).")
                    Text("2. Sul secondo telefono collegati a quel Wi‑Fi.")
                    Text("3. Inquadra il QR qui sotto con la Fotocamera del secondo telefono e apri il link in Safari.")
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
            .navigationTitle("Collega")
        }
    }
}
