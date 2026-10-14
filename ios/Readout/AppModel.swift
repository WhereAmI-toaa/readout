import AVFoundation
import SwiftUI
import UIKit

/// Ties the camera, Claude, the reader and the screen together.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let reader: Reader
    let camera = Camera()
    private let google: GoogleTTS
    private let cues = Cues()

    // Answer card
    @Published var current: Entry = .example
    @Published var cardFinal = true
    @Published var working = false
    @Published var quiet: String?
    @Published var tag = "Example"
    @Published var tagKind: TagKind = .plain
    @Published var meta = "Tap play to hear how answers sound"
    @Published var playerReady = true
    @Published var history: [Entry] = []

    // Camera and auto answer
    @Published var cameraState: CameraState = .starting
    @Published var still: UIImage?
    @Published var busy = false
    @Published var hint = "Hold steady on a question"
    @Published var ring: Double = 0
    @Published var torchOn = false
    @Published var zoom: CGFloat = 1

    // Chrome
    @Published var toast: String?
    @Published var toastWarn = false
    @Published var showSettings = false
    @Published var showSaved = false
    @Published var expanded = false
    @Published var googleStatus = "Paste your key, pick a voice, and tap Test."
    @Published var googleStatusOK: Bool?

    enum TagKind { case plain, answer, working, error }
    enum CameraState { case starting, ready, denied, unavailable }
    enum Trigger { case auto, tap, photo }

    /// Where the guide brackets sit on screen, for cropping the close-up.
    var viewSize: CGSize = .zero
    var bracketRect: CGRect = .zero

    private var task: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var ema: Float = 1
    private var run: Float = 0
    private var steadyMs: Double = 0
    private var armed = true
    private var textPresent = false
    private var lastFire = Date.distantPast
    private var lastStreamLen = 0
    private var readingStarted = false
    private var isActive = true
    let demo = UserDefaults.standard.bool(forKey: "ReadoutDemo")

    init() {
        let s = AppSettings()
        let g = GoogleTTS()
        settings = s
        google = g
        reader = Reader(settings: s, google: g)
        history = s.keepHistory ? HistoryStore.load() : []
        reader.onFinished = { [weak self] in
            guard let self else { return }
            if self.settings.cues && self.settings.voiceOn { self.cues.done(volume: self.settings.volume) }
        }
        reader.onWarn = { [weak self] msg in self?.show(msg, warn: true) }
        camera.onFrame = { @Sendable [weak self] stats in
            Task { @MainActor in self?.onFrame(stats) }
        }
        camera.onText = { @Sendable [weak self] present in
            Task { @MainActor in self?.textPresent = present }
        }
        if UserDefaults.standard.bool(forKey: "ReadoutDemoSettings") { showSettings = true }
    }

    // MARK: Lifecycle

    func startCamera() {
        if demo { cameraState = .unavailable; return }
        camera.start { @Sendable [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok { self.cameraState = .ready; self.armed = true; self.steadyMs = 0 }
                else {
                    self.cameraState = AVAuthorization.denied ? .denied : .unavailable
                }
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isActive = phase == .active
        if phase == .active { startCamera() } else if phase == .background { camera.stop(); torchOn = false }
    }

    // MARK: Toasts

    func show(_ msg: String, warn: Bool = false, seconds: Double = 3.8) {
        toast = msg
        toastWarn = warn
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Auto answer

    private func onFrame(_ s: FrameStats) {
        guard cameraState == .ready, settings.auto, !settings.anthropicKey.isEmpty, isActive, !showSettings, !showSaved else {
            if !busy { ring = 0 }
            steadyMs = 0
            return
        }
        ema = ema * 0.5 + s.nm * 0.5
        run = s.nm > 0.2 ? run + s.nm : 0
        if s.nm > 0.36 || run > 0.9 { armed = true; steadyMs = 0 }
        let lit = s.std >= 4 && s.mean > 18
        let steady = lit && ema < 0.26
        steadyMs = steady ? steadyMs + 200 : 0
        let hold = Double(settings.holdMs)

        if settings.waitForVoice && reader.active {
            ring = 0
            if reader.phase == .paused { hint = "Paused. Play or stop to move on." }
            else if armed && !busy { hint = "New page seen. Scanning after this answer." }
            else { hint = reader.pass == 1 ? "Reading the answer" : "Repeating the answer" }
            return
        }
        if busy { ring = 0; hint = "Thinking"; return }
        if !armed { ring = 0; hint = "Done. Move to the next question."; return }
        if !lit || !textPresent { ring = 0; hint = "Point at some text"; return }
        if !steady { ring = 0; hint = "Hold steady on a question"; return }
        ring = min(1, steadyMs / hold)
        hint = "Hold still"
        let gapOK = Date().timeIntervalSince(lastFire) > (settings.voiceOn ? 1.2 : 2.5) && Date().timeIntervalSince(reader.endedAt) > 0.7
        if steadyMs >= hold && gapOK {
            armed = false
            steadyMs = 0
            ask(.auto)
        }
    }

    var hintText: String {
        if settings.anthropicKey.isEmpty { return "Add your Anthropic API key in Settings" }
        if !settings.auto { return busy ? "Thinking" : "Frame the question, then tap the shutter" }
        return hint
    }

    // MARK: Asking Claude

    func shutterTapped() {
        if busy { task?.cancel(); return }
        armed = false
        ask(.tap)
    }

    func ask(_ trigger: Trigger, image: UIImage? = nil) {
        guard !busy else { return }
        guard !settings.anthropicKey.isEmpty else {
            showSettings = true
            show("Paste your Anthropic API key to start.")
            return
        }
        if image == nil && cameraState != .ready {
            show("The camera isn't on. Use the photo button to pick a picture instead.", warn: true)
            return
        }
        reader.stop()
        busy = true
        still = image
        ring = 0
        if settings.cues && settings.voiceOn { cues.capture(volume: settings.volume) }
        beginAnswer()
        let owner = UUID().uuidString
        task = Task { [weak self] in
            guard let self else { return }
            await self.runAsk(image: image, owner: owner)
            self.busy = false
            self.lastFire = Date()
        }
    }

    private func beginAnswer() {
        working = true
        quiet = nil
        cardFinal = false
        playerReady = false
        tag = "Reading"
        tagKind = .working
        meta = "Taking the photo"
        lastStreamLen = 0
        readingStarted = false
    }

    private func runAsk(image: UIImage?, owner: String) async {
        let t0 = Date()
        var photo = image
        if photo == nil { photo = await captureSharp() }
        guard let photo else { fail("The camera didn't take a photo. Try again."); return }
        if Task.isCancelled { stopped(); return }
        meta = "Sending to Claude"
        let images = prepare(photo, fromCamera: image == nil)
        guard !images.isEmpty else { fail("That photo couldn't be prepared. Try again."); return }
        let prompt = Prompt.build(extra: settings.extra, imageCount: images.count)
        do {
            let text = try await ClaudeAPI.stream(
                key: settings.anthropicKey, model: settings.model, think: settings.thinkHarder,
                images: images, prompt: prompt,
                onText: { @Sendable [weak self] t in
                    Task { @MainActor in
                        guard let self, self.busy else { return }
                        self.handleStream(t, done: false, owner: owner)
                    }
                })
            if Task.isCancelled { stopped(); return }
            handleStream(text, done: true, owner: owner)
            let pd = ReplyParser.parse(text, done: true)
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            if pd.found {
                var e = pd.entry()
                e.ts = Date()
                current = e
                cardFinal = true
                tag = "Answer"
                tagKind = .answer
                meta = "\(secs) s · \(Models.name(settings.model))" + (settings.thinkHarder ? " · thought harder" : "")
                playerReady = true
                pushHistory(e)
            } else {
                tag = "No text"
                tagKind = .plain
                meta = "\(secs) s"
                quiet = "Nothing to answer here. Get closer so the text fills the brackets, then try again."
                working = false
                playerReady = false
            }
        } catch is CancellationError {
            stopped()
        } catch let e as ClaudeError {
            if reader.owner == owner { reader.stop() }
            fail(e.friendly)
            if e.status == 401 { showSettings = true }
        } catch {
            if reader.owner == owner { reader.stop() }
            if Task.isCancelled { stopped() } else { fail("Something went wrong reaching Claude. Try again.") }
        }
    }

    private func handleStream(_ text: String, done: Bool, owner: String) {
        if !done && text.count < lastStreamLen { return }
        lastStreamLen = text.count
        let pd = ReplyParser.parse(text, done: done)
        if pd.found {
            current = pd.entry()
            working = false
            cardFinal = done
            if !done { tag = "Answering" }
        }
        let complete: String
        if done { complete = text } else if let nl = text.lastIndex(of: "\n") { complete = String(text[...nl]) } else { complete = "" }
        let ps = done ? pd : ReplyParser.parse(complete, done: false)
        guard ps.found, settings.voiceOn else { return }
        let plan = Speech.plan(ps.entry(), withSteps: settings.readSteps, repeatWhat: settings.repeatWhat)
        guard !plan.first.isEmpty else { return }
        if !readingStarted {
            readingStarted = true
            playerReady = true
            reader.start(plan.first, repeat: plan.again, final: done, passes: settings.repeats, owner: owner)
        } else if reader.owner == owner {
            reader.update(plan.first, repeat: plan.again, final: done)
        }
    }

    private func stopped() {
        tag = "Stopped"
        tagKind = .plain
        meta = ""
        working = false
        if current == .example || !cardFinal { quiet = "Stopped before an answer came back." }
    }

    private func fail(_ msg: String) {
        tag = "Couldn't answer"
        tagKind = .error
        meta = ""
        working = false
        quiet = msg
        playerReady = false
    }

    /// Takes a photo; if it came out soft, takes one more and keeps the sharper.
    private func captureSharp() async -> UIImage? {
        guard let first = await camera.capturePhoto() else { return nil }
        let a = ImagePrep.upright(first)
        let sa = ImagePrep.sharpness(a)
        if sa >= 140 { return a }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let second = await camera.capturePhoto() else { return a }
        let b = ImagePrep.upright(second)
        return ImagePrep.sharpness(b) > sa ? b : a
    }

    private func prepare(_ photo: UIImage, fromCamera: Bool) -> [ClaudeImage] {
        let up = ImagePrep.upright(photo)
        let high = Models.highRes(settings.model) && settings.photoDetail != .standard
        let maxLong: CGFloat = high ? 2576 : 1568
        let maxTokens = high ? 4784 : 1568
        var out: [ClaudeImage] = []
        let full = ImagePrep.fit(up, maxLong: maxLong, maxTokens: maxTokens)
        if let d = ImagePrep.jpeg(full) { out.append(ClaudeImage(label: "Image 1: the whole view.", jpeg: d)) }
        if fromCamera, settings.photoDetail == .closeUp, bracketRect.width > 0 {
            let pad = bracketRect.insetBy(dx: -bracketRect.width * 0.1, dy: -bracketRect.height * 0.12)
            let r = ImagePrep.visibleRect(imageSize: up.size, viewSize: viewSize, rectInView: pad)
            if let crop = ImagePrep.crop(up, r) {
                let c = ImagePrep.fit(crop, maxLong: maxLong, maxTokens: maxTokens)
                if let d = ImagePrep.jpeg(c) { out.append(ClaudeImage(label: "Image 2: a sharper close-up of the area inside the guide brackets.", jpeg: d)) }
            }
        }
        return out
    }

    // MARK: Saved answers

    private func pushHistory(_ e: Entry) {
        history.insert(e, at: 0)
        if history.count > 25 { history.removeLast(history.count - 25) }
        if settings.keepHistory { HistoryStore.save(history) }
    }

    func clearHistory() {
        history = []
        HistoryStore.save([])
    }

    func open(_ e: Entry) {
        reader.stop()
        current = e
        cardFinal = true
        working = false
        quiet = nil
        tag = "Saved"
        tagKind = .answer
        meta = e.ts.formatted(date: .abbreviated, time: .shortened)
        playerReady = true
        showSaved = false
        play(passes: 1)
    }

    // MARK: Player

    func play(passes: Int = 1) {
        let plan = Speech.plan(current, withSteps: settings.readSteps, repeatWhat: settings.repeatWhat)
        guard !plan.first.isEmpty else { return }
        reader.start(plan.first, repeat: plan.again, final: true, passes: passes, owner: "manual")
    }

    func playPause() {
        switch reader.phase {
        case .paused: reader.resume()
        case .idle: play()
        default: reader.pause()
        }
    }

    func cycleSpeed() {
        let speeds: [Double] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1]
        let next = speeds.first { $0 > settings.rate + 0.001 } ?? speeds[0]
        settings.rate = next
        show("Reading speed \(Self.rateLabel(next)). Applies from the next line.", seconds: 2.2)
    }

    static func rateLabel(_ r: Double) -> String {
        var s = String(format: "%.2f", r)
        if s.hasSuffix("0") { s.removeLast() }
        return s + "×"
    }

    func copy() {
        UIPasteboard.general.string = current.copyText
        show("Copied.")
    }

    func toggleMute() {
        settings.voiceOn.toggle()
        if !settings.voiceOn { reader.stop() }
        show(settings.voiceOn ? "Sound on. Answers will be read aloud." : "Muted. Answers show on screen only.")
    }

    func toggleAuto() {
        settings.auto.toggle()
        armed = true
        steadyMs = 0
        show(settings.auto ? "Auto answer on. Hold steady on a question." : "Auto answer off. Tap the shutter to answer.")
    }

    func toggleTorch() {
        torchOn.toggle()
        camera.setTorch(torchOn)
    }

    func setZoom(_ z: CGFloat) {
        zoom = max(1, min(6, z))
        camera.setZoom(zoom)
    }

    // MARK: Google test

    func testGoogle() {
        guard !settings.googleKey.isEmpty else { googleStatus = "Paste your Google API key first."; googleStatusOK = false; return }
        googleStatus = "Testing..."
        googleStatusOK = nil
        let line = "This is your Google voice. x equals negative 3 over 4."
        let key = settings.googleKey, voice = settings.googleVoice, rate = settings.rate, cap = settings.googleCap
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.google.synth(line, key: key, voice: voice, rate: rate, capOn: cap)
                self.googleStatus = "Key works. This voice will read your answers."
                self.googleStatusOK = true
                self.reader.test([line])
            } catch {
                self.googleStatus = (error as? GoogleError)?.friendly ?? "Google voice failed."
                self.googleStatusOK = false
            }
        }
    }
}

enum AVAuthorization {
    static var denied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }
}
