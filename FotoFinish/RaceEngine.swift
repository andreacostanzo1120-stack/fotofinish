import Foundation
import SwiftUI
import UIKit

final class RaceEngine: ObservableObject {
    enum Phase {
        case idle, armed, running, finished
    }

    let store = DataStore()
    let hub = Hub()
    let camera = CameraGate()
    let signal = StartSignal()

    private var server: LocalServer?
    private var pageData = Data()
    private var timer: Timer?
    private var tickCount = 0
    private var currentRun = 0
    private var timeoutItem: DispatchWorkItem?

    @Published var mode: RaceMode = .soundToRemote
    @Published var phase: Phase = .idle
    @Published var statusText = "Pronto"
    @Published var resultTime: Double?
    @Published var lastRun: Run?
    @Published var gates: [GateInfo] = []
    @Published var urls: [String] = []
    @Published var serverMessage = "Avvio server…"
    @Published var athlete: String = ""
    @Published var distance: Double = 100
    @Published var voiceOn = true
    @Published var cameraSensitivity: Double = 0.75 {
        didSet { camera.setSensitivity(cameraSensitivity) }
    }

    /// Istante di partenza (orologio HostClock)
    var t0: Double = 0

    init() {
        athlete = UserDefaults.standard.string(forKey: "athlete") ?? store.athletes.first ?? ""
        let d = UserDefaults.standard.double(forKey: "distance")
        distance = d > 0 ? d : 100
    }

    // MARK: Avvio servizi

    func startServices() {
        guard server == nil else { return }
        if let url = Bundle.main.url(forResource: "gate", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            pageData = data
        }
        signal.prepare()
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
        if mode.usesLocalCamera {
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

    // MARK: Gara

    func startRun() {
        guard phase == .idle || phase == .finished else { return }
        currentRun += 1
        let run = currentRun
        resultTime = nil
        lastRun = nil
        t0 = 0
        UserDefaults.standard.set(distance, forKey: "distance")
        UserDefaults.standard.set(athlete, forKey: "athlete")
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
            statusText = "In attesa del passaggio al primo cancello"
        case .soundToRemote, .singlePhone:
            beginSoundSequence(run)
        }
    }

    private func beginSoundSequence(_ run: Int) {
        statusText = "Ai vostri posti"
        if voiceOn { signal.say("Ai vostri posti") }
        let wait = voiceOn ? 2.6 : 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.currentRun == run, self.phase == .armed else { return }
            self.statusText = "Pronti"
            if self.voiceOn { self.signal.say("Pronti") }
            let hold = Double.random(in: 1.6...2.6)
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

    private func localTrigger(_ t: Double) {
        switch mode {
        case .flying:
            if phase == .armed {
                t0 = t
                phase = .running
                statusText = "In corsa"
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .singlePhone:
            if phase == .running && t > t0 + 0.3 {
                finish(at: t, uncertainty: nil)
            }
        case .soundToRemote:
            break
        }
    }

    private func remoteTrigger(run: Int, time: Double, rttMs: Double?) {
        guard mode.usesRemote, run == currentRun, phase == .running, time > t0 + 0.3 else { return }
        finish(at: time, uncertainty: rttMs.map { $0 / 2 })
    }

    private func finish(at t1: Double, uncertainty: Double?) {
        let elapsed = t1 - t0
        guard elapsed > 0 else { return }
        resultTime = elapsed
        phase = .finished
        statusText = "Arrivo"
        hub.setArmed(false, run: currentRun)
        camera.disarm()
        timeoutItem?.cancel()
        let r = Run(athlete: athlete, distance: distance, mode: mode, time: elapsed, uncertaintyMs: uncertainty)
        lastRun = r
        store.add(r)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

        case ("GET", "/favicon.ico"):
            return WebResponse(status: 204, contentType: "text/plain", body: Data())

        default:
            return WebResponse.text("Non trovato", status: 404)
        }
    }
}
