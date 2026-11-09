import SwiftUI
import UniformTypeIdentifiers

struct MoreView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var store: DataStore
    @EnvironmentObject var settings: AppSettings
    @State private var share: ShareItem?
    @State private var showImporter = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Collegamenti") {
                    NavigationLink {
                        ConnectView()
                    } label: {
                        HStack {
                            Label("Secondo telefono", systemImage: "qrcode")
                            Spacer()
                            Circle()
                                .fill(e.gates.isEmpty ? Color.orange : Color.green)
                                .frame(width: 10, height: 10)
                        }
                    }
                    NavigationLink {
                        CalibrationView()
                    } label: {
                        Label("Calibra i due telefoni", systemImage: "scope")
                    }
                    NavigationLink {
                        AthletesView()
                    } label: {
                        Label("Atleti", systemImage: "person.2")
                    }
                }

                Section("Aspetto") {
                    Picker("Tema", selection: $settings.theme) {
                        Text("Automatico").tag(0)
                        Text("Chiaro").tag(1)
                        Text("Scuro").tag(2)
                    }
                    Picker("Dimensione dei caratteri", selection: $settings.textSize) {
                        Text("Normale").tag(0)
                        Text("Grande").tag(1)
                        Text("Molto grande").tag(2)
                    }
                    Button {
                        settings.fieldMode = true
                        e.selectedTab = 0
                    } label: {
                        Label("Modalità campo (schermo intero)", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

                Section("Start") {
                    Toggle("Voce “Ai vostri posti, pronti”", isOn: $settings.voiceOn)
                    Stepper(value: $settings.holdMin, in: 1.0...4.0, step: 0.2) {
                        Text("Attesa minima prima del beep: \(String(format: "%.1f", settings.holdMin)) s")
                    }
                    Stepper(value: $settings.holdMax, in: 1.0...4.0, step: 0.2) {
                        Text("Attesa massima prima del beep: \(String(format: "%.1f", settings.holdMax)) s")
                    }
                }

                Section("Fotofinish e fotocamera") {
                    Picker("Gli atleti corrono", selection: $settings.leftToRight) {
                        Text("Da sinistra a destra").tag(true)
                        Text("Da destra a sinistra").tag(false)
                    }
                    Picker("Fotogrammi massimi", selection: $settings.maxFPS) {
                        Text("60").tag(60)
                        Text("120").tag(120)
                        Text("240").tag(240)
                    }
                    Text("Meno fotogrammi = meno calore e batteria. Si applica alla prossima apertura dell’app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Dati") {
                    Button {
                        if let url = store.makeBackupURL() { share = ShareItem(url: url) }
                    } label: {
                        Label("Esporta backup", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importa backup", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        if let url = csvURL() { share = ShareItem(url: url) }
                    } label: {
                        Label("Esporta tutte le prove in CSV", systemImage: "tablecells")
                    }
                }

                Section("Guida rapida") {
                    NavigationLink("Come si usa") { GuideView() }
                }

                Section {
                    Text("FotoFinish 0.2 · tempi non omologati")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Altro")
            .sheet(item: $share) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                message = store.restore(from: data)
            } else {
                message = "Non riesco a leggere il file."
            }
        case .failure:
            message = "Importazione annullata."
        }
    }

    private func num(_ d: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", d).replacingOccurrences(of: ".", with: ",")
    }

    private func csvURL() -> URL? {
        var csv = "data;atleta;distanza_m;modalita;tempo_s;velocita_kmh;reazione_ms;incertezza_ms;serie;ripetizione\n"
        let formatter = ISO8601DateFormatter()
        for r in store.runs.reversed() {
            let cols: [String] = [
                formatter.string(from: r.date),
                r.athlete,
                num(r.distance, 1),
                r.mode.title,
                num(r.time, 3),
                num(r.speedKMH, 2),
                r.reactionMs.map { num($0, 0) } ?? "",
                r.uncertaintyMs.map { num($0, 1) } ?? "",
                r.series.map { String($0) } ?? "",
                r.rep.map { String($0) } ?? ""
            ]
            csv += cols.joined(separator: ";") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fotofinish-prove.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
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
                    e.runners = e.runners.filter { store.athletes.contains($0) }
                }
            }
            Section {
                Text("Se elimini un atleta, i suoi tempi restano nello storico.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Atleti")
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !store.athletes.contains(name) else { return }
        store.athletes.append(name)
        newName = ""
    }
}

// MARK: - Calibrazione

struct CalibrationView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            Section("A cosa serve") {
                Text("La fotocamera di Safari ha un piccolo ritardo rispetto a quella di questo telefono. La calibrazione lo misura e lo corregge, così i tempi tra i due telefoni diventano più precisi.")
                    .font(.subheadline)
            }
            Section("Come si fa") {
                Text("1. Collega il secondo telefono e attiva la sua fotocamera.")
                Text("2. Mettili uno accanto all’altro, puntati nella stessa direzione.")
                Text("3. Premi Avvia e passa la mano davanti a entrambi, 6 volte, alternando sinistra-destra e destra-sinistra.")
            }
            .font(.subheadline)

            Section("Stato") {
                if e.gates.isEmpty {
                    Text("Secondo telefono non collegato.").foregroundColor(.orange)
                }
                if e.calibrating {
                    ProgressView(value: Double(e.calibCount), total: 6)
                    Text(e.calibMessage).font(.footnote)
                    Button("Interrompi", role: .destructive) { e.stopCalibration() }
                } else {
                    Button("Avvia la calibrazione") { e.startCalibration() }
                        .disabled(e.gates.isEmpty || e.phase == .armed || e.phase == .running)
                    if !e.calibMessage.isEmpty {
                        Text(e.calibMessage).font(.footnote).foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text("Correzione attuale")
                    Spacer()
                    Text(String(format: "%+.0f ms", settings.remoteCorrection * 1000))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Button("Azzera la correzione") { e.resetCalibration() }
                    .disabled(settings.remoteCorrection == 0 || e.calibrating)
            }
        }
        .navigationTitle("Calibrazione")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if e.calibrating { e.stopCalibration() }
        }
    }
}

// MARK: - Guida

struct GuideView: View {
    var body: some View {
        List {
            Section("Un tempo, in tre passi") {
                Text("1. Gara: scegli la modalità e chi corre.")
                Text("2. Tocca VIA (o ARMA nella volata).")
                Text("3. Il tempo compare da solo e viene salvato.")
            }
            Section("Le tre modalità") {
                Text("Sparo: questo telefono dà il via con voce e beep, l’altro telefono ferma il tempo all’arrivo.")
                Text("Volata: il tempo parte e si ferma quando qualcuno passa davanti alle due fotocamere.")
                Text("1 telefono: via sonoro e arrivo sulla stessa fotocamera, per provare da soli.")
            }
            Section("Più atleti insieme") {
                Text("Seleziona più nomi in “Chi corre”. Dopo l’arrivo apri il fotofinish: tocca il torso di ogni atleta sull’immagine e assegna il nome.")
            }
            Section("Allenamento") {
                Text("Nella scheda Allenamento crei il lavoro del giorno, ad esempio 2×3×150. Quando cronometri, i tempi vanno da soli nella casella giusta di ogni atleta. Puoi anche scriverli a mano toccando una casella.")
            }
            Section("Consigli") {
                Text("Usa un treppiede: il telefono deve stare fermo.")
                Text("Metti la fotocamera all’altezza del busto, in linea con il traguardo.")
                Text("Più luce c’è, meglio funziona la fotocamera ad alta velocità.")
                Text("Tieni entrambi i telefoni con lo schermo acceso.")
            }
            Section {
                Text("I tempi sono molto più precisi di un cronometro a mano ma non sono omologati per record ufficiali.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Guida")
        .navigationBarTitleDisplayMode(.inline)
    }
}
