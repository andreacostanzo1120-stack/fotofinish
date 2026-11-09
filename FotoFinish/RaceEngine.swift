import Foundation
import SwiftUI
import UIKit

final class RaceEngine: ObservableObject {
    enum Phase {
        case idle, armed, running, finished
    }

    let settings = AppSettings()
    let store = DataStore()
    let hub = Hub()
    let camera = CameraGate()
    let signal = StartSignal()

    private var server: LocalServer?
    private var pageData = Data()
    private var timer: Timer?
    private var tickCount = 0
    private var currentRun = 0
    private var currentRaceId = UUID()
    private var timeoutItem: DispatchWorkItem?
    private var raceT0ForRun: [Int: Double] = [:]
    private var raceIdForRun: [Int: UUID] = [:]
    private var acceptedRawForRun: [Int: Double] = [:]
    private var remoteUnc: Double?
    private var rearmTime = 0.0

    // Calibrazione
    private let calibRunId = -777
    private var calibDeltas: [Double] = []
    private var calibLocalT: Double?
    private var calibRemoteT: Double?

    @Published var selectedTab = 0
    @Published var mode: RaceMode = .soundToRemote {
        didSet { refreshCameraUsage() }
    }
    @Published var reversed = false {
        didSet { refreshCameraUsage() }
    }
    @Published var measureReaction = false {
        didSet { refreshCameraUsage() }
    }
    @Published var runners: [String] = []
    @Published var distance: Double = 100
    @Published var activeSessionId: UUID? = nil {
        didSet { UserDefaults.standard.set(activeSessionId?.uuidString, forKey: "activeSession") }
    }
    @Published var phase: Phase = .idle
    @Published var statusText = "Pronto"
    @Published var resultTime: Double?
    @Published var reactionMs: Double?
    @Published var lastRaceId: UUID?
    @Published var stripPending = false
    @Published var stripTick = 0
    @Published var gates: [GateInfo] = []
    @Published var urls: [String] = []
    @Published var serverMessage = "Avvio server…"
    @Published var cameraSensitivity: Double = 0.75 {
        didSet { camera.setSensitivity(cameraSensitivity) }
    }

    @Published var calibrating = false
    @Published var calibCount = 0
    @Published var calibMessage = ""

    /// Istante di partenza (orologio HostClock)
    var t0: Double = 0

    var activeSession: Session? {
        guard let id = activeSessionId else { return nil }
        return store.sessions.first { $0.id == id }
    }

    var needsCamera: Bool {
        mode.usesLocalCamera || (mode == .soundToRemote && measureReaction) || calibrating
    }

    var lastRaceRuns: [Run] {
        guard let id = lastRaceId else { return [] }
        return store.runs(forRace: id)
    }

    init() {
        let d = UserDefaults.standard
        if let saved = d.stringArray(forKey: "runners"), !saved.isEmpty {
            runners = saved
        } else if let first = store.athletes.first {
            runners = [first]
        }
        let dist = d.double(forKey: "distance")
        distance = dist > 0 ? dist : 100
        if let str = d.string(forKey: "activeSession"), let id = UUID(uuidString: str),
           store.sessions.contains(where: { $0.id == id }) {
            activeSessionId = id
        }
    }

    // MARK: Avvio servizi

    func startServices() {
        guard server == nil else { return }
        if let url = Bundle.main.url(forResource: "gate", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            pageData = data
        }
        signal.prepare()
        camera.targetFPS = Double(settings.maxFPS)
        camera.setSensitivity(cameraSensitivity)
        camera.onTrigger = { [weak self] t in
            DispatchQueue.main.async { self?.localTrigger(t) }
        }
        startServer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
        refreshCameraUsage()
    }

    private func startServer() {
        let s = LocalServer(port: 8443) { [weak self] req in
            self?.handle(req) ?? WebResponse.text("Non disponibile", status: 503)
        }
        s.onState = { [weak self] message in
            DispatchQueue.main.async { self?.serverMessage = message }
        }
        do {
            try s.start()
            server = s
        } catch {
            serverMessage = "Errore server: \(error.localizedDescription)"
        }
    }

    func restartServer() {
        server?.stop()
        server = nil
        startServer()
    }

    func refreshCameraUsage() {
        guard server != nil else { return }
        if needsCamera {
            camera.start()
        } else {
            camera.stop()
        }
    }

    private func tick() {
        let g = hub.active(now: HostClock.now())
        if g != gates { gates = g }
        tickCount += 1
        if tickCount % 4 == 1 {
            let u = NetInfo.urls(port: 8443)
            if u != urls { urls = u }
        }
    }

    // MARK: Atleti e allenamento

    func toggleRunner(_ name: String) {
        if let i = runners.firstIndex(of: name) {
            runners.remove(at: i)
        } else {
            runners.append(name)
        }
        UserDefaults.standard.set(runners, forKey: "runners")
    }

    func startSession(_ id: UUID) {
        guard let s = store.sessions.first(where: { $0.id == id }) else { return }
        activeSessionId = id
        runners = s.athletes
        distance = s.plan.distance
        UserDefaults.standard.set(runners, forKey: "runners")
    }

    // MARK: Gara

    func startRun() {
        guard phase == .idle || phase == .finished else { return }
        if let s = activeSession { distance = s.plan.distance }
        currentRun += 1
        let run = currentRun
        currentRaceId = UUID()
        raceIdForRun[run] = currentRaceId
        resultTime = nil
        reactionMs = nil
        lastRaceId = nil
        stripPending = false
        remoteUnc = nil
        t0 = 0
        UserDefaults.standard.set(distance, forKey: "distance")
        phase = .armed

        if mode.usesRemote { hub.setArmed(true, run: run) }
        if mode.usesLocalCamera { camera.arm() }

        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentRun == run,
                  self.phase == .armed || self.phase == .running else { return }
            self.cancel(message: "Tempo scaduto")
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: item)

        switch mode {
        case .flying:
            statusText = reversed ? "In attesa del passaggio al telefono 2" : "In attesa del passaggio al primo cancello"
        case .soundToRemote, .singlePhone:
            beginSoundSequence(run)
        case .manual:
            break
        }
    }

    private func beginSoundSequence(_ run: Int) {
        statusText = "Ai vostri posti"
        let voice = settings.voiceOn
        if voice { signal.say("Ai vostri posti") }
        let wait = voice ? 2.6 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.currentRun == run, self.phase == .armed else { return }
            self.statusText = "Pronti"
            if voice { self.signal.say("Pronti") }
            let lo = min(self.settings.holdMin, self.settings.holdMax)
            let hi = max(self.settings.holdMin, self.settings.holdMax)
            let hold = lo == hi ? lo : Double.random(in: lo...hi)
            if self.mode == .soundToRemote && self.measureReaction {
                self.rearmTime = HostClock.now()
                self.camera.arm()
            }
            self.t0 = self.signal.scheduleBeep(after: hold)
            self.phase = .running
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                guard let self = self, self.currentRun == run, self.phase == .running else { return }
                self.statusText = "VIA!"
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
    }

    func cancel(message: String = "Annullato") {
        currentRun += 1
        hub.setArmed(false, run: currentRun)
        camera.disarm()
        signal.stop()
        timeoutItem?.cancel()
        phase = .idle
        statusText = message
    }

    func displayTime() -> Double {
        switch phase {
        case .running:
            return max(0, HostClock.now() - t0)
        case .finished:
            return resultTime ?? 0
        default:
            return 0
        }
    }

    private func startClock(at t: Double) {
        t0 = t
        phase = .running
        statusText = "In corsa"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Passaggi rilevati

    private func localTrigger(_ t: Double) {
        if calibrating {
            calibLocalT = t
            checkCalibration()
            return
        }
        switch mode {
        case .flying:
            if !reversed {
                if phase == .armed { startClock(at: t) }
            } else if phase == .running && t > t0 + 0.2 {
                finish(at: t, uncertainty: remoteUnc, remoteRaw: nil)
            }
        case .singlePhone:
            if phase == .running && t > t0 + 0.3 {
                finish(at: t, uncertainty: nil, remoteRaw: nil)
            }
        case .soundToRemote:
            if measureReaction && phase == .running && reactionMs == nil && t > rearmTime {
                let ms = (t - t0) * 1000
                reactionMs = ms
                if ms < 100 { statusText = "Partenza anticipata" }
            }
        case .manual:
            break
        }
    }

    private func remoteTrigger(run: Int, time rawTime: Double, rttMs: Double?) {
        if calibrating && run == calibRunId {
            calibRemoteT = rawTime
            checkCalibration()
            return
        }
        guard mode.usesRemote, run == currentRun else { return }
        let t = rawTime - settings.remoteCorrection
        let unc = rttMs.map { $0 / 2 }
        switch mode {
        case .soundToRemote:
            if phase == .running && t > t0 + 0.3 {
                finish(at: t, uncertainty: unc, remoteRaw: rawTime)
            }
        case .flying:
            if reversed {
                if phase == .armed {
                    remoteUnc = unc
                    startClock(at: t)
                }
            } else if phase == .running && t > t0 + 0.2 {
                finish(at: t, uncertainty: unc, remoteRaw: rawTime)
            }
        default:
            break
        }
    }

    private func finish(at t1: Double, uncertainty: Double?, remoteRaw: Double?) {
        let elapsed = t1 - t0
        guard elapsed > 0 else { return }
        let run = currentRun
        let raceId = currentRaceId
        let base = t0
        resultTime = elapsed
        phase = .finished
        statusText = "Arrivo"
        hub.setArmed(false, run: run)
        camera.disarm()
        timeoutItem?.cancel()
        raceT0ForRun[run] = base
        if let raw = remoteRaw { acceptedRawForRun[run] = raw }

        let athlete = runners.count == 1 ? runners[0] : ""
        let r = Run(athlete: athlete, distance: distance, mode: mode, time: elapsed,
                    uncertaintyMs: uncertainty, raceId: raceId, sessionId: activeSessionId,
                    reactionMs: reactionMs)
        store.addAssigning(r)
        lastRaceId = raceId
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        stripPending = true
        if remoteRaw == nil {
            captureLocalStrip(raceId: raceId, t1: t1, base: base)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.stripPending = false
            }
        }
    }

    // MARK: Fotofinish

    private func captureLocalStrip(raceId: UUID, t1: Double, base: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let snap = self.camera.snapshot(from: t1 - 1.5, to: t1 + 3.0)
                DispatchQueue.main.async {
                    if let snap = snap,
                       let jpeg = UIImage(cgImage: snap.image).jpegData(compressionQuality: 0.85) {
                        let info = StripInfo(raceId: raceId, colTimes: snap.times.map { $0 - base },
                                             source: "iPhone principale")
                        self.store.saveStrip(raceId: raceId, jpeg: jpeg, info: info)
                        self.stripTick += 1
                    }
                    self.stripPending = false
                }
            }
        }
    }

    private func receiveStrip(run: Int, rawT: Double, jpeg: Data, times: [Double]) {
        guard let raceId = raceIdForRun[run], let base = raceT0ForRun[run],
              let accepted = acceptedRawForRun[run], abs(accepted - rawT) < 0.002,
              times.count > 5, !jpeg.isEmpty else { return }
        let rel = times.map { $0 - settings.remoteCorrection - base }
        let info = StripInfo(raceId: raceId, colTimes: rel, source: "Safari")
        store.saveStrip(raceId: raceId, jpeg: jpeg, info: info)
        stripTick += 1
        stripPending = false
    }

    // MARK: Calibrazione

    func startCalibration() {
        guard phase == .idle || phase == .finished else { return }
        calibrating = true
        calibDeltas = []
        calibCount = 0
        calibLocalT = nil
        calibRemoteT = nil
        calibMessage = "Passa la mano davanti a entrambe le fotocamere, alternando la direzione (1 secondo e mezzo tra un passaggio e l’altro)."
        hub.setArmed(true, run: calibRunId)
        camera.start()
        camera.arm()
    }

    func stopCalibration() {
        calibrating = false
        hub.setArmed(false, run: currentRun)
        camera.disarm()
        refreshCameraUsage()
    }

    private func checkCalibration() {
        guard let l = calibLocalT, let r = calibRemoteT else { return }
        if abs(r - l) > 0.5 {
            // passaggi non abbinati: tengo solo il più recente
            if l > r { calibRemoteT = nil } else { calibLocalT = nil }
            return
        }
        calibDeltas.append(r - l)
        calibLocalT = nil
        calibRemoteT = nil
        calibCount = calibDeltas.count
        if calibDeltas.count >= 6 {
            let mean = calibDeltas.reduce(0, +) / Double(calibDeltas.count)
            settings.remoteCorrection = mean
            calibMessage = String(format: "Fatto. Correzione applicata: %+.0f ms.", mean * 1000)
            stopCalibration()
        } else {
            calibMessage = "Passaggi registrati: \(calibDeltas.count) di 6"
        }
    }

    func resetCalibration() {
        settings.remoteCorrection = 0
        calibMessage = "Correzione azzerata."
    }

    // MARK: Server (eseguito sulla coda di rete: usa solo oggetti thread-safe)

    func handle(_ req: WebRequest) -> WebResponse {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            if pageData.isEmpty { return WebResponse.text("Pagina non trovata", status: 404) }
            return WebResponse.html(pageData)

        case ("GET", "/api/time"):
            return WebResponse.json(String(format: "{\"t\":%.6f}", HostClock.now()))

        case ("POST", "/api/hello"):
            let id = hub.register(name: "Telefono")
            return WebResponse.json("{\"id\":\(id)}")

        case ("GET", "/api/state"):
            let id = Int(req.query["id"] ?? "") ?? 0
            hub.touch(id)
            let s = hub.state()
            let known = hub.isKnown(id)
            return WebResponse.json("{\"armed\":\(s.armed),\"run\":\(s.run),\"known\":\(known)}")

        case ("POST", "/api/sync"):
            let j = req.json
            let id = (j["id"] as? Int) ?? 0
            if let rtt = j["rtt"] as? Double { hub.setRTT(id, rtt) }
            return WebResponse.json("{\"ok\":true}")

        case ("POST", "/api/trigger"):
            let j = req.json
            let id = (j["id"] as? Int) ?? 0
            let run = (j["run"] as? Int) ?? -1
            let t = (j["t"] as? Double) ?? 0
            let rtt = j["rtt"] as? Double
            hub.touch(id)
            DispatchQueue.main.async { [weak self] in
                self?.remoteTrigger(run: run, time: t, rttMs: rtt)
            }
            return WebResponse.json("{\"ok\":true}")

        case ("POST", "/api/strip"):
            let j = req.json
            let run = (j["run"] as? Int) ?? -1
            let t = (j["t"] as? Double) ?? 0
            let times = (j["times"] as? [Double]) ?? []
            var jpeg = Data()
            if let b64 = j["jpeg"] as? String, let d = Data(base64Encoded: b64) { jpeg = d }
            DispatchQueue.main.async { [weak self] in
                self?.receiveStrip(run: run, rawT: t, jpeg: jpeg, times: times)
            }
            return WebResponse.json("{\"ok\":true}")

        case ("GET", "/favicon.ico"):
            return WebResponse(status: 204, contentType: "text/plain", body: Data())

        default:
            return WebResponse.text("Non trovato", status: 404)
        }
    }
}
