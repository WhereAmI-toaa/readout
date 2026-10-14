import Foundation

struct GoogleError: Error {
    var code: String          // "cap", "network", "google"
    var http: Int = 0
    var message: String = ""
    var status: String = ""

    var friendly: String {
        if code == "cap" { return "Google voice paused to stay in the free tier this month." }
        if code == "network" { return "Couldn't reach Google. Check your connection." }
        let m = message
        func has(_ p: String) -> Bool { m.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        if has("API key not valid|API_KEY_INVALID") { return "Google says that key isn't valid. Copy it again from the Credentials page." }
        if has("ios|bundle") && has("block") { return "Google blocked this app for that key. In the key's restrictions, allow iOS apps with bundle ID io.github.whereami-toaa.readout, or set Application restrictions to None." }
        if has("referer|referrer") { return "Google blocked the request. In the key's Website restrictions, make sure https://whereami-toaa.github.io/* is listed." }
        if has("has not been used|is disabled|SERVICE_DISABLED|not been enabled") { return "Text-to-Speech isn't enabled for that project yet. Enable it, wait a minute, then test again." }
        if has("billing") { return "Billing isn't turned on for that Google project yet." }
        if has("not authorized|API_KEY_SERVICE_BLOCKED|blocked") { return "That key isn't allowed to use Text-to-Speech. Check the key's API restrictions." }
        if http == 429 || status == "RESOURCE_EXHAUSTED" { return "Google is rate limiting. Wait a moment." }
        return "Google said: " + (m.isEmpty ? "error \(http)" : m)
    }
}

/// Google's Chirp 3 HD voices. Audio is cached so repeats are free, and usage is counted per month.
actor GoogleTTS {
    static let cap = 950_000
    static let voices: [(name: String, gender: String)] = [
        ("Charon", "male"), ("Kore", "female"), ("Puck", "male"), ("Aoede", "female"), ("Orus", "male"), ("Leda", "female"),
        ("Fenrir", "male"), ("Zephyr", "female"), ("Achird", "male"), ("Achernar", "female"), ("Algenib", "male"), ("Autonoe", "female"),
        ("Algieba", "male"), ("Callirrhoe", "female"), ("Alnilam", "male"), ("Despina", "female"), ("Enceladus", "male"), ("Erinome", "female"),
        ("Iapetus", "male"), ("Gacrux", "female"), ("Rasalgethi", "male"), ("Laomedeia", "female"), ("Sadachbia", "male"), ("Pulcherrima", "female"),
        ("Sadaltager", "male"), ("Sulafat", "female"), ("Schedar", "male"), ("Vindemiatrix", "female"), ("Umbriel", "male"), ("Zubenelgenubi", "male")
    ]

    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<Data, Error>] = [:]

    static func monthKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    static func usage() -> Int {
        let d = UserDefaults.standard
        return d.string(forKey: "gUsageMonth") == monthKey() ? d.integer(forKey: "gUsageChars") : 0
    }
    private static func addUsage(_ n: Int) {
        let d = UserDefaults.standard
        let u = usage() + n
        d.set(monthKey(), forKey: "gUsageMonth")
        d.set(u, forKey: "gUsageChars")
    }

    func synth(_ text: String, key: String, voice: String, rate: Double, capOn: Bool) async throws -> Data {
        let k = "\(voice)|\(String(format: "%.2f", rate))|\(text)"
        if let d = cache[k] { return d }
        if let t = inflight[k] { return try await t.value }
        if capOn && Self.usage() + text.count > Self.cap { throw GoogleError(code: "cap") }
        let task = Task<Data, Error> { try await Self.fetch(text, key: key, voice: voice, rate: rate) }
        inflight[k] = task
        do {
            let data = try await task.value
            inflight[k] = nil
            Self.addUsage(text.count)
            cache[k] = data
            order.append(k)
            if order.count > 200 { cache[order.removeFirst()] = nil }
            return data
        } catch {
            inflight[k] = nil
            throw error
        }
    }

    private static func fetch(_ text: String, key: String, voice: String, rate: Double) async throws -> Data {
        var comps = URLComponents(string: "https://texttospeech.googleapis.com/v1/text:synthesize")!
        comps.queryItems = [URLQueryItem(name: "key", value: key)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // Your key is restricted to the Readout website, so the app identifies itself the same way.
        req.setValue("https://whereami-toaa.github.io/readout/", forHTTPHeaderField: "Referer")
        if let bundle = Bundle.main.bundleIdentifier { req.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        let body: [String: Any] = [
            "input": ["text": text],
            "voice": ["languageCode": String(voice.prefix(5)), "name": voice],
            "audioConfig": ["audioEncoding": "MP3", "speakingRate": min(2, max(0.25, rate))]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw GoogleError(code: "network") }
        let http = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard http == 200 else {
            let err = obj?["error"] as? [String: Any]
            throw GoogleError(code: "google", http: http, message: err?["message"] as? String ?? "", status: err?["status"] as? String ?? "")
        }
        guard let b64 = obj?["audioContent"] as? String, let audio = Data(base64Encoded: b64) else {
            throw GoogleError(code: "google", http: http, message: "No audio came back.")
        }
        return audio
    }
}
