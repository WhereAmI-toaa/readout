import Foundation
import SwiftUI

enum Models {
    static let haiku = "claude-haiku-4-5-20251001"
    static let sonnet = "claude-sonnet-5-5"
    static let opus = "claude-opus-5-5"
    static let all: [(id: String, name: String)] = [(haiku, "Haiku 4.5"), (sonnet, "Sonnet 5.5"), (opus, "Opus 5.5")]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    /// Haiku 4.5 sees images at the standard size. Sonnet and Opus 5.5 see up to 2576 px.
    static func highRes(_ id: String) -> Bool { id != haiku }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case device, google
    var id: String { rawValue }
    var title: String { self == .device ? "iPhone voice" : "Google HD" }
}

enum RepeatWhat: String, CaseIterable, Identifiable {
    case answers, all
    var id: String { rawValue }
    var title: String { self == .answers ? "Answers only" : "Everything" }
}

enum PhotoDetail: String, CaseIterable, Identifiable {
    case standard, high, closeUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .closeUp: return "High + close-up"
        }
    }
    var note: String {
        switch self {
        case .standard: return "Smallest photo. About half a cent per scan on Sonnet."
        case .high: return "Full-resolution photo. About a cent per scan on Sonnet."
        case .closeUp: return "Full photo plus a sharp close-up of what's inside the brackets. Best for small labels and diagrams. About 2 to 3 cents per scan on Sonnet."
        }
    }
}

/// Every setting lives here and saves itself. API keys go to the Keychain.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var anthropicKey: String { didSet { Keychain.set(anthropicKey, "anthropic") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var thinkHarder: Bool { didSet { d.set(thinkHarder, forKey: "thinkHarder") } }
    @Published var photoDetail: PhotoDetail { didSet { d.set(photoDetail.rawValue, forKey: "photoDetail") } }
    @Published var extra: String { didSet { d.set(extra, forKey: "extra") } }

    @Published var voiceOn: Bool { didSet { d.set(voiceOn, forKey: "voiceOn") } }
    @Published var engine: VoiceEngine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    @Published var googleKey: String { didSet { Keychain.set(googleKey, "google") } }
    @Published var googleVoice: String { didSet { d.set(googleVoice, forKey: "googleVoice") } }
    @Published var googleCap: Bool { didSet { d.set(googleCap, forKey: "googleCap") } }
    @Published var rate: Double { didSet { d.set(rate, forKey: "rate") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }

    @Published var repeats: Int { didSet { d.set(repeats, forKey: "repeats") } }
    @Published var repeatWhat: RepeatWhat { didSet { d.set(repeatWhat.rawValue, forKey: "repeatWhat") } }
    @Published var pauseMs: Int { didSet { d.set(pauseMs, forKey: "pauseMs") } }
    @Published var termPauseMs: Int { didSet { d.set(termPauseMs, forKey: "termPauseMs") } }
    @Published var readSteps: Bool { didSet { d.set(readSteps, forKey: "readSteps") } }
    @Published var sayAgain: Bool { didSet { d.set(sayAgain, forKey: "sayAgain") } }
    @Published var cues: Bool { didSet { d.set(cues, forKey: "cues") } }

    @Published var auto: Bool { didSet { d.set(auto, forKey: "auto") } }
    @Published var holdMs: Int { didSet { d.set(holdMs, forKey: "holdMs") } }
    @Published var waitForVoice: Bool { didSet { d.set(waitForVoice, forKey: "waitForVoice") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }

    init() {
        d.register(defaults: [
            "model": Models.sonnet, "thinkHarder": false, "photoDetail": PhotoDetail.closeUp.rawValue, "extra": "",
            "voiceOn": true, "engine": VoiceEngine.device.rawValue, "voiceID": "",
            "googleVoice": "en-US-Chirp3-HD-Charon", "googleCap": true, "rate": 0.8, "volume": 1.0,
            "repeats": 2, "repeatWhat": RepeatWhat.answers.rawValue, "pauseMs": 1200, "termPauseMs": 650,
            "readSteps": false, "sayAgain": true, "cues": true,
            "auto": true, "holdMs": 900, "waitForVoice": true, "keepHistory": true
        ])
        anthropicKey = Keychain.get("anthropic")
        model = d.string(forKey: "model") ?? Models.sonnet
        thinkHarder = d.bool(forKey: "thinkHarder")
        photoDetail = PhotoDetail(rawValue: d.string(forKey: "photoDetail") ?? "") ?? .closeUp
        extra = d.string(forKey: "extra") ?? ""
        voiceOn = d.bool(forKey: "voiceOn")
        engine = VoiceEngine(rawValue: d.string(forKey: "engine") ?? "") ?? .device
        voiceID = d.string(forKey: "voiceID") ?? ""
        googleKey = Keychain.get("google")
        googleVoice = d.string(forKey: "googleVoice") ?? "en-US-Chirp3-HD-Charon"
        googleCap = d.bool(forKey: "googleCap")
        rate = d.double(forKey: "rate")
        volume = d.double(forKey: "volume")
        repeats = d.integer(forKey: "repeats")
        repeatWhat = RepeatWhat(rawValue: d.string(forKey: "repeatWhat") ?? "") ?? .answers
        pauseMs = d.integer(forKey: "pauseMs")
        termPauseMs = d.integer(forKey: "termPauseMs")
        readSteps = d.bool(forKey: "readSteps")
        sayAgain = d.bool(forKey: "sayAgain")
        cues = d.bool(forKey: "cues")
        auto = d.bool(forKey: "auto")
        holdMs = d.integer(forKey: "holdMs")
        waitForVoice = d.bool(forKey: "waitForVoice")
        keepHistory = d.bool(forKey: "keepHistory")
    }
}

enum Keychain {
    private static let service = "readout"
    static func get(_ key: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ value: String, _ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum Theme {
    static let ink = Color(hex: 0x0D0F12)
    static let panel = Color(hex: 0x15181D)
    static let panel2 = Color(hex: 0x1E2228)
    static let line = Color(hex: 0x2C313A)
    static let text = Color(hex: 0xECE9E2)
    static let muted = Color(hex: 0x979EA9)
    static let amber = Color(hex: 0xF2B53A)
    static let amberInk = Color(hex: 0x1B1406)
    static let danger = Color(hex: 0xFF8A78)
    static let scrim = Color(hex: 0x0D0F12).opacity(0.82)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
