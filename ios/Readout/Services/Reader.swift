import AVFoundation

/// Reads an answer line by line: pauses between lines, a beat between terms, repeats, and a transport.
@MainActor
final class Reader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum Phase { case idle, waiting, speaking, gap, paused }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var now = ""
    @Published private(set) var nowPart: Int?
    @Published private(set) var pass = 1
    @Published private(set) var passes = 1
    @Published private(set) var cur = 0
    @Published private(set) var isFinal = true
    @Published private(set) var again = false
    @Published private(set) var count = 0

    private(set) var owner: String?
    private(set) var endedAt = Date.distantPast
    var active: Bool { phase != .idle }

    var onFinished: (() -> Void)?
    var onWarn: ((String) -> Void)?

    private let settings: AppSettings
    private let google: GoogleTTS
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var items: [SpeechItem] = []
    private var repeatItems: [SpeechItem]?
    private var idx = 0
    private var token = 0
    private var lineStart = Date()
    private var utteranceDone: [ObjectIdentifier: () -> Void] = [:]
    private var playerDone: (id: ObjectIdentifier, fn: () -> Void)?
    private var lastWarn = Date.distantPast

    init(settings: AppSettings, google: GoogleTTS) {
        self.settings = settings
        self.google = google
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    // MARK: Voices

    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                let ka = (a.quality.rawValue, a.language == "en-US" ? 1 : 0)
                let kb = (b.quality.rawValue, b.language == "en-US" ? 1 : 0)
                return ka != kb ? ka > kb : a.name < b.name
            }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private func voice() -> AVSpeechSynthesisVoice? {
        if !settings.voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: settings.voiceID) { return v }
        return Self.englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Same scale as the web app: 1.0 is the normal rate, lower is slower.
    static func avRate(_ r: Double) -> Float {
        let def = AVSpeechUtteranceDefaultSpeechRate, mx = AVSpeechUtteranceMaximumSpeechRate, mn = AVSpeechUtteranceMinimumSpeechRate
        let v: Float = r < 1 ? Float(r) * def : def + Float(r - 1) * (mx - def)
        return min(mx, max(mn, v))
    }

    private var useGoogle: Bool {
        settings.engine == .google && !settings.googleKey.isEmpty && !(settings.googleCap && GoogleTTS.usage() >= GoogleTTS.cap)
    }

    // MARK: Audio session

    private func activateAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
    }

    private func deactivateAudio() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.active else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Transport

    private var curList: [SpeechItem] { pass == 1 ? items : (repeatItems ?? items) }

    private func halt() {
        token += 1
        utteranceDone.removeAll()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        playerDone = nil
        player?.stop()
        player = nil
    }

    func start(_ items: [SpeechItem], repeat rep: [SpeechItem]?, final: Bool, passes: Int, owner: String) {
        halt()
        activateAudio()
        self.items = items
        self.repeatItems = rep
        self.isFinal = final
        self.idx = 0
        self.cur = 0
        self.pass = 1
        self.passes = max(1, passes)
        self.owner = owner
        self.now = ""
        self.nowPart = nil
        self.again = false
        self.count = items.count
        phase = .waiting
        go()
    }

    func update(_ items: [SpeechItem], repeat rep: [SpeechItem]?, final: Bool) {
        self.items = items
        self.repeatItems = rep
        self.isFinal = final
        self.count = curList.count
        if phase == .waiting { go() }
    }

    func stop() { if active { finish(silent: true) } }

    func pause() {
        guard active, phase != .paused else { return }
        halt()
        if again { again = false; idx = 0 }
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        activateAudio()
        phase = .waiting
        go()
    }

    func back() {
        guard active else { return }
        let justStarted = phase == .speaking && Date().timeIntervalSince(lineStart) < 1.5
        let target = again ? 0 : max(0, justStarted ? cur - 1 : cur)
        halt()
        again = false
        idx = target
        activateAudio()
        phase = .waiting
        go()
    }

    func next() {
        guard active else { return }
        let target = again ? 0 : cur + 1
        halt()
        again = false
        idx = target
        activateAudio()
        phase = .waiting
        go()
    }

    private func go() {
        guard phase != .paused && phase != .idle else { return }
        let list = curList
        count = list.count
        if idx >= list.count {
            if !isFinal && pass == 1 { phase = .waiting; return }
            let nextList = repeatItems ?? items
            if pass < passes && !nextList.isEmpty {
                pass += 1
                idx = 0
                cur = -1
                count = nextList.count
                if settings.sayAgain {
                    again = true
                    speakLine(SpeechItem(t: "Again.", k: .other, i: nil)) { [weak self] in
                        guard let self else { return }
                        self.again = false
                        self.gap(Double(min(self.settings.pauseMs, 900)) / 1000) { self.go() }
                    }
                } else {
                    gap(Double(settings.pauseMs) / 1000) { [weak self] in self?.go() }
                }
                return
            }
            finish(silent: false)
            return
        }
        cur = idx
        let item = list[idx]
        speakLine(item) { [weak self] in
            guard let self else { return }
            self.idx = self.cur + 1
            let ms = item.k == .label ? 250 : self.settings.pauseMs
            self.gap(Double(ms) / 1000) { self.go() }
        }
    }

    private func gap(_ seconds: Double, _ then: @escaping () -> Void) {
        token += 1
        let my = token
        phase = .gap
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, my == self.token else { return }
            self.phase = .waiting
            then()
        }
    }

    private func speakLine(_ item: SpeechItem, after: @escaping () -> Void) {
        phase = .speaking
        now = item.t
        if item.k != .other { nowPart = item.i }
        lineStart = Date()
        let chunks = Speech.chunkTerms(item.t, enabled: settings.termPauseMs > 0)
        if useGoogle { prefetch(chunks) }
        var ci = 0
        func step() {
            token += 1
            let my = token
            let text = chunks[ci]
            ci += 1
            let done: () -> Void = { [weak self] in
                guard let self, my == self.token else { return }
                if ci >= chunks.count { after(); return }
                self.token += 1
                let my2 = self.token
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(self.settings.termPauseMs) / 1000) { [weak self] in
                    guard let self, my2 == self.token else { return }
                    step()
                }
            }
            if useGoogle { speakGoogle(text, my: my, done: done) } else { speakDevice(text, done: done) }
        }
        step()
    }

    private func speakDevice(_ text: String, done: @escaping () -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice()
        u.rate = Self.avRate(settings.rate)
        u.volume = Float(settings.volume)
        utteranceDone[ObjectIdentifier(u)] = done
        synth.speak(u)
    }

    private func speakGoogle(_ text: String, my: Int, done: @escaping () -> Void) {
        let key = settings.googleKey, voiceName = settings.googleVoice, rate = settings.rate, capOn = settings.googleCap
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.google.synth(text, key: key, voice: voiceName, rate: rate, capOn: capOn)
                guard my == self.token else { return }
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.volume = Float(self.settings.volume)
                self.player = p
                self.playerDone = (ObjectIdentifier(p), done)
                if !p.play() { self.playerDone = nil; self.speakDevice(text, done: done) }
            } catch {
                guard my == self.token else { return }
                self.warn((error as? GoogleError)?.friendly ?? "Google voice failed.")
                self.speakDevice(text, done: done)
            }
        }
    }

    private func prefetch(_ chunks: [String]) {
        var texts = Array(chunks.dropFirst())
        let list = curList
        for k in 1...2 {
            if idx + k < list.count { texts += Speech.chunkTerms(list[idx + k].t, enabled: settings.termPauseMs > 0) }
        }
        let key = settings.googleKey, voiceName = settings.googleVoice, rate = settings.rate, capOn = settings.googleCap
        let g = google
        Task.detached {
            for t in texts { _ = try? await g.synth(t, key: key, voice: voiceName, rate: rate, capOn: capOn) }
        }
    }

    private func warn(_ msg: String) {
        guard Date().timeIntervalSince(lastWarn) > 20 else { return }
        lastWarn = Date()
        onWarn?(msg + " Using the iPhone voice for now.")
    }

    private func finish(silent: Bool) {
        halt()
        phase = .idle
        now = ""
        nowPart = nil
        again = false
        owner = nil
        endedAt = Date()
        if !silent { onFinished?() }
        deactivateAudio()
    }

    /// Tests a voice without touching the current answer.
    func test(_ lines: [String]) {
        start(lines.map { SpeechItem(t: $0, k: .other, i: nil) }, repeat: nil, final: true, passes: 1, owner: "test")
    }

    var status: String {
        if !active { return settings.voiceOn ? "Tap play to hear it" : "Voice is muted. Tap play to hear it anyway." }
        let more = !isFinal && pass == 1 ? "+" : ""
        let line = again ? "Repeating" : "Line \(min(max(cur, 0) + 1, max(count, 1))) of \(count)\(more)"
        let passText = passes > 1 ? (pass == 1 ? "First read · " : "Repeat \(pass - 1) of \(passes - 1) · ") : ""
        let waiting = phase == .waiting && !isFinal && idx >= count ? "Waiting for the answer · " : ""
        return (phase == .paused ? "Paused · " : "") + waiting + passText + line
    }

    // MARK: Delegates

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let f = self.utteranceDone.removeValue(forKey: id) { f() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceDone[id] = nil }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        Task { @MainActor in
            guard let pd = self.playerDone, pd.id == id else { return }
            self.playerDone = nil
            pd.fn()
        }
    }
}
