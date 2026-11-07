import Foundation
import AVFoundation

final class StartSignal {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private var beep: AVAudioPCMBuffer?
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        beep = StartSignal.makeBeep(format: format)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        try? engine.start()
    }

    /// Programma il beep tra `delay` secondi.
    /// Restituisce l'istante (orologio HostClock) in cui il suono esce dall'altoparlante.
    func scheduleBeep(after delay: Double) -> Double {
        guard let buf = beep else { return HostClock.now() + delay }
        if !engine.isRunning { try? engine.start() }
        let hostNow = mach_absolute_time()
        let clockNow = HostClock.now()
        let when = hostNow + AVAudioTime.hostTime(forSeconds: delay)
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: when))
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        return clockNow + delay + latency
    }

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        u.volume = 1.0
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() {
        player.stop()
        synth.stopSpeaking(at: .immediate)
    }

    private static func makeBeep(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.4
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let attack = min(1.0, t / 0.002)
            let release = min(1.0, (duration - t) / 0.01)
            let envelope = attack * release
            let tone = sin(2 * Double.pi * 1000 * t) * 0.7 + sin(2 * Double.pi * 2000 * t) * 0.25
            channel[i] = Float(tone * envelope)
        }
        return buf
    }
}
