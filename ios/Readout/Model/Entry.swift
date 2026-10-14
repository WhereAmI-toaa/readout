import Foundation

/// One piece of an answer: what's shown on screen (`d`, may contain LaTeX) and what's spoken (`s`).
struct Field: Codable, Equatable {
    var d: String
    var s: String
}

struct Part: Codable, Equatable {
    var label: String
    var p: Field?
    var w: [Field]
    var a: Field?
}

struct Entry: Codable, Equatable, Identifiable {
    var id = UUID()
    var q: Field?
    var parts: [Part]
    var ts: Date

    static let example = Entry(
        q: Field(d: "Let \\(f(x) = x^2 \\sin x\\).", s: "Let f of x equal x squared sine x."),
        parts: [
            Part(label: "a",
                 p: Field(d: "Find \\(f'(x)\\).", s: "Find f prime of x."),
                 w: [Field(d: "Product rule: \\((uv)' = u'v + uv'\\)", s: "Use the product rule.")],
                 a: Field(d: "\\(f'(x) = 2x\\sin x + x^2\\cos x\\)", s: "f prime of x equals 2 x sine x, plus x squared cosine x.")),
            Part(label: "b",
                 p: Field(d: "Find \\(f'(0)\\).", s: "Find f prime of 0."),
                 w: [Field(d: "\\(f'(0) = 0 + 0\\)", s: "Plug in 0. Both terms are 0.")],
                 a: Field(d: "\\(f'(0) = 0\\)", s: "f prime of 0 equals 0."))
        ],
        ts: Date(timeIntervalSince1970: 0))

    /// Plain text version for the clipboard.
    var copyText: String {
        var out: [String] = []
        if let q { out.append(Speech.plain(q.d)) }
        for p in parts {
            if !p.label.isEmpty || p.p != nil {
                out.append((p.label.isEmpty ? "" : p.label + ". ") + Speech.plain(p.p?.d ?? ""))
            }
            for w in p.w { out.append("   " + Speech.plain(w.d)) }
            if let a = p.a { out.append("   Answer: " + Speech.plain(a.d)) }
        }
        return out.joined(separator: "\n")
    }

    var title: String {
        if let q { return Speech.plain(q.d) }
        if let p = parts.first?.p { return Speech.plain(p.d) }
        return "Photo"
    }

    var answerSummary: String {
        parts.map { ($0.label.isEmpty ? "" : $0.label + ". ") + Speech.plain($0.a?.d ?? "") }.joined(separator: "   ")
    }
}

struct SpeechItem: Equatable {
    enum Kind { case question, part, label, work, answer, other }
    var t: String
    var k: Kind
    var i: Int?
}

/// Saved answers, kept as a small JSON file in the app's documents folder.
enum HistoryStore {
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json")
    }
    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([Entry].self, from: data)) ?? []
    }
    static func save(_ entries: [Entry]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(Array(entries.prefix(25))) { try? data.write(to: url, options: .atomic) }
    }
}
