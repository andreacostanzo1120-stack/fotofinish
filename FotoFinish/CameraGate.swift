import Foundation
import AVFoundation
import UIKit
import SwiftUI

/// Cancello a fotocamera: guarda una striscia stretta al centro dell'immagine
/// e segnala il primo istante in cui qualcosa la attraversa.
final class CameraGate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    let session = AVCaptureSession()
    var onTrigger: ((Double) -> Void)?

    @Published var permissionDenied = false
    @Published var running = false

    // Valori letti dalla UI (lettura non critica)
    private(set) var lastRatio: Double = 0
    private(set) var fps: Double = 0

    private let videoQueue = DispatchQueue(label: "fotofinish.camera", qos: .userInteractive)
    private let lock = NSLock()
    private var device: AVCaptureDevice?
    private var configured = false

    // Stato condiviso (protetto da lock)
    private var armedFlag = false
    private var armedSince = 0.0
    private var ratioThreshold: Float = 0.16
    private var lineIsColumn = true
    private var resetBackground = true

    // Stato usato solo sulla coda della fotocamera
    private let gridAcross = 6
    private let gridAlong = 48
    private var cur = [Float](repeating: 0, count: 288)
    private var bg = [Float](repeating: 0, count: 288)
    private var bgReady = false
    private var streak = 0
    private var streakStart = 0.0
    private var deadUntil = 0.0
    private var frameCount = 0
    private var fpsWindowStart = 0.0

    // MARK: Controllo

    func start() {
        DispatchQueue.main.async {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(self.orientationChanged),
                                                   name: UIDevice.orientationDidChangeNotification, object: nil)
            self.updateOrientation()
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.videoQueue.async {
                if !self.configured { self.configure() }
                if self.configured && !self.session.isRunning { self.session.startRunning() }
                let isRunning = self.session.isRunning
                DispatchQueue.main.async { self.running = isRunning }
            }
        }
    }

    func stop() {
        videoQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }

    func arm() {
        lock.lock()
        armedFlag = true
        armedSince = HostClock.now()
        resetBackground = true
        lock.unlock()
        lockExposure(true)
    }

    func disarm() {
        lock.lock()
        armedFlag = false
        lock.unlock()
        lockExposure(false)
    }

    /// s da 0 (poco sensibile) a 1 (molto sensibile)
    func setSensitivity(_ s: Double) {
        lock.lock()
        ratioThreshold = Float(0.5 - 0.45 * s)
        lock.unlock()
    }

    @objc private func orientationChanged() {
        updateOrientation()
    }

    private func updateOrientation() {
        let o = UIDevice.current.orientation
        var column: Bool?
        if o.isLandscape { column = true }
        if o.isPortrait { column = false }
        if let c = column {
            lock.lock()
            lineIsColumn = c
            lock.unlock()
        }
    }

    // MARK: Configurazione

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        device = dev
        selectFormat(dev)
        configured = true
    }

    /// Sceglie il formato con più fotogrammi al secondo (max 240) tra 1280 e 1920 pixel di larghezza.
    private func selectFormat(_ dev: AVCaptureDevice) {
        let target = 240.0
        var best: AVCaptureDevice.Format?
        var bestFPS = 0.0
        var bestWidth = Int32.max
        for f in dev.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if dims.width < 1280 || dims.width > 1920 { continue }
            let maxFPS = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
            let capped = min(maxFPS, target)
            if capped > bestFPS || (capped == bestFPS && dims.width < bestWidth) {
                best = f
                bestFPS = capped
                bestWidth = dims.width
            }
        }
        guard let format = best, bestFPS > 0 else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(bestFPS))
            dev.activeVideoMinFrameDuration = duration
            dev.activeVideoMaxFrameDuration = duration
            dev.unlockForConfiguration()
        } catch {
            // si usa il formato predefinito
        }
    }

    private func lockExposure(_ lockIt: Bool) {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            if lockIt {
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
            } else {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            dev.unlockForConfiguration()
        } catch {
            // ignorato
        }
    }

    // MARK: Analisi dei fotogrammi

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        frameCount += 1
        if fpsWindowStart == 0 { fpsWindowStart = pts }
        if pts - fpsWindowStart >= 1.0 {
            fps = Double(frameCount) / (pts - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = pts
        }

        lock.lock()
        let armed = armedFlag
        let since = armedSince
        let threshold = ratioThreshold
        let isColumn = lineIsColumn
        let reset = resetBackground
        resetBackground = false
        lock.unlock()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)

        let block = 4
        let thick = max(24, (isColumn ? w : h) / 40)
        let total = gridAcross * gridAlong
        var idx = 0
        for a in 0..<gridAcross {
            for b in 0..<gridAlong {
                let x0: Int
                let y0: Int
                if isColumn {
                    x0 = w / 2 - thick / 2 + (a * thick) / gridAcross
                    y0 = (b * (h - block)) / gridAlong
                } else {
                    y0 = h / 2 - thick / 2 + (a * thick) / gridAcross
                    x0 = (b * (w - block)) / gridAlong
                }
                let x = min(max(x0, 0), w - block)
                let y = min(max(y0, 0), h - block)
                var sum = 0
                for dy in 0..<block {
                    let row = p + (y + dy) * stride + x
                    for dx in 0..<block {
                        sum += Int(row[dx])
                    }
                }
                cur[idx] = Float(sum) / Float(block * block)
                idx += 1
            }
        }

        if reset || !bgReady {
            bg = cur
            bgReady = true
            streak = 0
            deadUntil = 0
        }

        // Compensa le variazioni globali di luminosità
        var meanDiff: Float = 0
        for i in 0..<total { meanDiff += cur[i] - bg[i] }
        meanDiff /= Float(total)
        var changed = 0
        for i in 0..<total {
            if abs(cur[i] - bg[i] - meanDiff) > 22 { changed += 1 }
        }
        let ratio = Float(changed) / Float(total)
        lastRatio = Double(ratio)

        let ready = armed && pts >= since + 0.8
        if !ready {
            for i in 0..<total { bg[i] += (cur[i] - bg[i]) * 0.15 }
            streak = 0
            return
        }

        if ratio > threshold {
            if streak == 0 { streakStart = pts }
            streak += 1
            if streak >= 2 && pts > deadUntil {
                deadUntil = pts + 1.5
                streak = 0
                onTrigger?(streakStart)
            }
        } else {
            streak = 0
            let rate = Float(1.0 / max(fps, 30.0) / 1.5)
            for i in 0..<total { bg[i] += (cur[i] - bg[i]) * rate }
        }
    }
}

// MARK: - Anteprima

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass garantisce il tipo
        return layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        previewLayer.videoGravity = .resizeAspect
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(rotated),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func rotated() {
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let c = previewLayer.connection, c.isVideoOrientationSupported else { return }
        switch UIDevice.current.orientation {
        case .landscapeLeft: c.videoOrientation = .landscapeRight
        case .landscapeRight: c.videoOrientation = .landscapeLeft
        case .portraitUpsideDown: c.videoOrientation = .portraitUpsideDown
        case .portrait: c.videoOrientation = .portrait
        default: break
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let running: Bool

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }
}
