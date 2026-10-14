import AVFoundation
import UIKit
import Vision

/// What the auto-answer logic needs from each analyzed frame.
struct FrameStats: Sendable {
    var nm: Float      // motion since the last frame, normalized by contrast
    var mean: Float
    var std: Float
}

/// Back camera: live preview, motion and text checks on video frames, full-resolution photos.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "readout.camera.session")
    private let videoQueue = DispatchQueue(label: "readout.camera.video")
    private(set) var device: AVCaptureDevice?
    private(set) var baseZoom: CGFloat = 1
    private var configured = false

    /// Called on a background queue about 5 times a second.
    var onFrame: (@Sendable (FrameStats) -> Void)?
    /// Called on a background queue with whether readable text is in the middle of the view.
    var onText: (@Sendable (Bool) -> Void)?

    private var lastGrid: [Float]?
    private var lastAnalysis = Date.distantPast
    private var lastTextCheck = Date.distantPast
    private var textBusy = false
    private var photoWaiter: CheckedContinuation<UIImage?, Never>?

    var hasTorch: Bool { device?.hasTorch ?? false }

    func start(_ done: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { done(false); return }
            self.sessionQueue.async {
                let ok = self.configure()
                if ok && !self.session.isRunning { self.session.startRunning() }
                done(ok)
            }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() -> Bool {
        if configured { return true }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        guard let dev = types.compactMap({ t in found.first { $0.deviceType == t } }).first,
              let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if let maxDim = dev.activeFormat.supportedMaxPhotoDimensions.last { photoOutput.maxPhotoDimensions = maxDim }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        if (try? dev.lockForConfiguration()) != nil {
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = .near }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            // Multi-lens cameras start on the ultra wide; begin on the main lens and let it switch to macro up close.
            if dev.isVirtualDevice, let first = dev.virtualDeviceSwitchOverVideoZoomFactors.first {
                baseZoom = CGFloat(truncating: first)
                dev.videoZoomFactor = baseZoom
            }
            dev.unlockForConfiguration()
        }
        device = dev
        configured = true
        return true
    }

    /// `factor` is relative to the normal 1x view.
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let z = max(dev.minAvailableVideoZoomFactor, min(min(dev.maxAvailableVideoZoomFactor, self.baseZoom * 6), self.baseZoom * factor))
            dev.videoZoomFactor = z
            dev.unlockForConfiguration()
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let dev = self.device, dev.hasTorch, (try? dev.lockForConfiguration()) != nil else { return }
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
        }
    }

    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = point; dev.focusMode = .autoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = point; dev.exposureMode = .autoExpose }
            dev.unlockForConfiguration()
            self.sessionQueue.asyncAfter(deadline: .now() + 2) {
                guard (try? dev.lockForConfiguration()) != nil else { return }
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.unlockForConfiguration()
            }
        }
    }

    // MARK: Photos

    /// A full-resolution still, upright for a phone held in portrait.
    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            sessionQueue.async {
                guard self.session.isRunning, self.photoWaiter == nil else { cont.resume(returning: nil); return }
                self.photoWaiter = cont
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                if let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        sessionQueue.async {
            let w = self.photoWaiter
            self.photoWaiter = nil
            w?.resume(returning: img)
        }
    }

    // MARK: Frame analysis

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 0.2, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        if let g = Motion.grid(pb) {
            var nm: Float = 1
            if let prev = lastGrid { nm = Motion.diff(g.blocks, prev) / max(g.std, 6) }
            lastGrid = g.blocks
            onFrame?(FrameStats(nm: nm, mean: g.mean, std: g.std))
        }
        if now.timeIntervalSince(lastTextCheck) >= 0.6 && !textBusy {
            lastTextCheck = now
            textBusy = true
            let present = Self.textPresent(pb)
            textBusy = false
            onText?(present)
        }
    }

    private static func textPresent(_ pb: CVPixelBuffer) -> Bool {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        req.regionOfInterest = CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
        guard (try? handler.perform([req])) != nil, let results = req.results else { return false }
        var chars = 0
        for o in results {
            if let c = o.topCandidates(1).first, c.confidence > 0.3 { chars += c.string.count }
        }
        return chars >= 8
    }
}

/// Motion on a coarse, contrast-normalized grid, so hand shake and exposure flicker don't count as moving.
enum Motion {
    static let AW = 64, AH = 48, BW = 16, BH = 12

    static func grid(_ pb: CVPixelBuffer) -> (blocks: [Float], mean: Float, std: Float)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 8, h > 8 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let cw = Double(w) * 0.7, ch = Double(h) * 0.7
        let x0 = (Double(w) - cw) / 2, y0 = (Double(h) - ch) / 2
        var px = [Float](repeating: 0, count: AW * AH)
        var sum: Float = 0
        for j in 0..<AH {
            for i in 0..<AW {
                var acc: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let x = min(w - 1, Int(x0 + (Double(i) + 0.25 + 0.5 * Double(dx)) * cw / Double(AW)))
                        let y = min(h - 1, Int(y0 + (Double(j) + 0.25 + 0.5 * Double(dy)) * ch / Double(AH)))
                        acc += Float(p[y * bpr + x])
                    }
                }
                let v = acc / 4
                px[j * AW + i] = v
                sum += v
            }
        }
        let n = Float(AW * AH)
        let mean = sum / n
        var vs: Float = 0
        for v in px { vs += (v - mean) * (v - mean) }
        let std = (vs / n).squareRoot()
        var blocks = [Float](repeating: 0, count: BW * BH)
        let bx = AW / BW, by = AH / BH
        for j in 0..<AH {
            for i in 0..<AW { blocks[(j / by) * BW + (i / bx)] += px[j * AW + i] - mean }
        }
        let cnt = Float(bx * by)
        for b in 0..<blocks.count { blocks[b] /= cnt }
        return (blocks, mean, std)
    }

    static func diff(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<n { s += abs(a[i] - b[i]) }
        return s / Float(n)
    }
}
