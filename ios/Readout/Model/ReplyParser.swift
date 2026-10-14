import Foundation

// MARK: - Regex helpers

extension String {
    func rx(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: template)
    }
    func has(_ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) != nil
    }
    /// Splits at every match of `pattern`, dropping the matched text.
    func splitting(_ pattern: String, _ options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [self] }
        let ns = self as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Speech text

enum Speech {
    static let greek: Set<String> = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda", "Sigma", "Phi", "Psi", "Omega"]

    /// Fallback: turns leftover LaTeX into words so math code is never read out literally.
    static func toSpeech(_ input: String) -> String {
        var t = input
        t = t.rx(#"\\\$\s?(\d[\d,.]*)"#, " $1 dollars ").rx(#"\\\$"#, " dollars ")
        t = t.rx(#"\\\(|\\\)|\\\[|\\\]|\$\$?"#, " ")
        t = t.rx(#"\\(left|right|big|Big|bigg|Bigg)\b"#, "")
        t = t.rx(#"\\(mathbf|vec|boldsymbol|hat|bar|mathrm|text|textbf|operatorname|mathit)\{([^{}]*)\}"#, " $2 ")
        t = t.rx(#"\\\|([^|]+?)\\\|"#, " the magnitude of $1 ")
        t = t.rx(#"\\lVert([\s\S]*?)\\rVert"#, " the magnitude of $1 ")
        t = t.rx(#"\\lvert([\s\S]*?)\\rvert"#, " the absolute value of $1 ")
        for _ in 0..<3 {
            t = t.rx(#"\\d?t?frac\{([^{}]*)\}\{([^{}]*)\}"#, " $1 over $2 ")
            t = t.rx(#"\\sqrt\[([^\]]*)\]\{([^{}]*)\}"#, " the $1 root of $2 ")
            t = t.rx(#"\\sqrt\{([^{}]*)\}"#, " the square root of $1 ")
        }
        t = t.rx(#"\|([^|]{1,40})\|"#, " the magnitude of $1 ")
        t = t.rx(#"\^\{?2\}?(?!\d)"#, " squared ").rx(#"\^\{?3\}?(?!\d)"#, " cubed ")
        t = t.rx(#"\^\{([^{}]*)\}"#, " to the $1 ").rx(#"\^(\w)"#, " to the $1 ")
        t = t.rx(#"_\{([^{}]*)\}"#, " sub $1 ").rx(#"_(\w)"#, " sub $1 ")
        t = t.rx(#"\\cdot"#, " times ").rx(#"\\times"#, " times ").rx(#"\\div"#, " divided by ")
        t = t.rx(#"\\pm"#, " plus or minus ").rx(#"\\approx"#, " approximately ")
        t = t.rx(#"\\(leq|le)\b"#, " is less than or equal to ").rx(#"\\(geq|ge)\b"#, " is greater than or equal to ")
        t = t.rx(#"\\(neq|ne)\b"#, " does not equal ").rx(#"\\infty"#, " infinity ").rx(#"\\to\b|\\rightarrow"#, " goes to ")
        t = t.rx(#"\\(sin|cos|tan|sec|csc|cot|ln|log|lim|int|sum|max|min)\b"#, " $1 ")
        t = replaceCommands(t)
        t = t.rx(#"[{}\\|]"#, " ")
        t = t.rx("<", " is less than ").rx(">", " is greater than ")
        t = t.rx(#"\s=\s|="#, " equals ")
        return t.rx(#"\s+"#, " ").trimmed
    }

    private static func replaceCommands(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\\([A-Za-z]+)"#) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let w = ns.substring(with: m.range(at: 1))
            out += greek.contains(w) ? " \(w.lowercased()) " : " "
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Anything spoken passes through this.
    static func speakable(_ s: String) -> String {
        s.has(#"\\[A-Za-z(\[)\]|$]|[{}^_]|\|\|"#) ? toSpeech(s.replacingOccurrences(of: "||", with: " ")) : s
    }

    static func plain(_ s: String) -> String {
        s.rx(#"\\\(|\\\)|\\\[|\\\]"#, "").rx(#"\s+"#, " ").trimmed
    }

    /// One sentence per line, so there's a pause between them.
    static func sentences(_ s: String) -> [String] {
        let text = s.rx(#"\s+"#, " ").trimmed
        guard !text.isEmpty, let re = try? NSRegularExpression(pattern: #"[.!?;]\s+(?=\S)"#) else { return text.isEmpty ? [] : [text] }
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + 1
            pieces.append(ns.substring(with: NSRange(location: last, length: end - last)).trimmed)
            last = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: last).trimmed)
        var out: [String] = []
        for t in pieces where !t.isEmpty {
            if let prev = out.last, t.split(separator: " ").count < 2, !prev.has(#"^(part|number)\b"#, .caseInsensitive) {
                out[out.count - 1] = prev + " " + t
            } else {
                out.append(t)
            }
        }
        return out
    }

    static let termSplit = #"\s+(?=(?:plus|minus|equals|times|divided by|over|is less than|is greater than|is at least|is at most|is approximately|approximately)\b)"#

    /// "12 minus 2 I sub 1 equals 0" -> ["12", "minus 2 I sub 1", "equals 0"], so each term gets its own beat.
    static func chunkTerms(_ t: String, enabled: Bool) -> [String] {
        let text = t.trimmed
        guard enabled, text.rangeOfCharacter(from: .decimalDigits) != nil, text.has(termSplit, .caseInsensitive) else { return [text] }
        var out: [String] = []
        for piece in text.splitting(termSplit, .caseInsensitive) {
            guard let re = try? NSRegularExpression(pattern: #"([,:])\s+"#) else { out.append(piece); continue }
            let ns = piece as NSString
            var last = 0
            for m in re.matches(in: piece, range: NSRange(location: 0, length: ns.length)) {
                let c = ns.substring(with: NSRange(location: last, length: m.range.location + 1 - last)).trimmed
                if !c.isEmpty { out.append(c) }
                last = m.range.location + m.range.length
            }
            let tail = ns.substring(from: last).trimmed
            if !tail.isEmpty { out.append(tail) }
        }
        return out.isEmpty ? [text] : out
    }

    static func labelSpoken(_ part: Part) -> String {
        guard !part.label.isEmpty else { return "" }
        return part.label.allSatisfy(\.isNumber) ? "Number \(part.label)." : "Part \(part.label)."
    }

    /// Spoken order: the question, then each part's text and its answer. Repeats read labels and answers only.
    static func plan(_ e: Entry, withSteps: Bool, repeatWhat: RepeatWhat) -> (first: [SpeechItem], again: [SpeechItem]?) {
        var first: [SpeechItem] = []
        var again: [SpeechItem] = []
        if let q = e.q, !q.s.isEmpty {
            for t in sentences(speakable(q.s)) { first.append(SpeechItem(t: t, k: .question, i: -1)) }
        }
        for (i, p) in e.parts.enumerated() {
            let lab = labelSpoken(p)
            if let pp = p.p, !pp.s.isEmpty {
                var ps = sentences(speakable(pp.s))
                if !lab.isEmpty, let f = ps.first, !f.has(#"^(part|number|question|problem)\b"#, .caseInsensitive) { ps[0] = lab + " " + f }
                for t in ps { first.append(SpeechItem(t: t, k: .part, i: i)) }
            } else if !lab.isEmpty {
                first.append(SpeechItem(t: lab, k: .label, i: i))
            }
            if withSteps {
                for w in p.w { for t in sentences(speakable(w.s)) { first.append(SpeechItem(t: t, k: .work, i: i)) } }
            }
            if let a = p.a, !a.s.isEmpty {
                let sa = speakable(a.s)
                let ans = sa.has(#"^answer\b"#, .caseInsensitive) ? sa : "Answer: " + sa
                let lines = sentences(ans)
                for t in lines { first.append(SpeechItem(t: t, k: .answer, i: i)) }
                if !lab.isEmpty { again.append(SpeechItem(t: lab, k: .label, i: i)) }
                for t in lines { again.append(SpeechItem(t: t, k: .answer, i: i)) }
            }
        }
        return (first, repeatWhat == .all ? nil : again)
    }
}

// MARK: - Reply parsing ("TAG: display || spoken" lines)

struct ParsedReply {
    var none = false
    var q: Field?
    var parts: [Part] = []
    var found: Bool { q != nil || !parts.isEmpty }
    func entry() -> Entry { Entry(q: q, parts: parts, ts: Date()) }
}

enum ReplyParser {
    private static let tagPattern = #"^[\s>*#-]*(?:\*\*)?(Q|PART[ \t]+([^:|*]{1,12}?)|W|A)(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(.*)$"#
    private static let tagRegex = try? NSRegularExpression(pattern: tagPattern)

    /// The divider is the last "||" outside math, so magnitude bars like |a||b| don't split the line.
    static func field(_ raw: String) -> Field {
        let chars = Array(raw)
        var depth = 0
        var cut = -1
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\\" {
                if n == "(" || n == "[" { depth += 1 } else if n == ")" || n == "]" { depth = max(0, depth - 1) }
                i += 2
                continue
            }
            if c == "|" && n == "|" && depth == 0 { cut = i; i += 2; continue }
            i += 1
        }
        if cut < 0 { return Field(d: raw.trimmed, s: "") }
        return Field(d: String(chars[0..<cut]).trimmed, s: String(chars[(cut + 2)...]).trimmed)
    }

    static func parse(_ text: String, done: Bool) -> ParsedReply {
        var out = ParsedReply()
        if text.trimmed.has(#"^NONE\.?$"#, .caseInsensitive) { out.none = done; return out }
        var parts: [Part] = []
        var q: Field?
        var tagged = false
        // Which field a continuation line belongs to.
        enum Slot { case none, q, p(Int), w(Int, Int), a(Int) }
        var last = Slot.none

        func append(_ f: inout Field, _ line: String) {
            if line.contains("||") {
                let g = field(line)
                f.d = (f.d + " " + g.d).trimmed
                f.s = (f.s + " " + g.s).trimmed
            } else if !f.s.isEmpty {
                f.s += " " + line.trimmed
            } else {
                f.d += " " + line.trimmed
            }
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmed.hasPrefix("```") { continue }
            let ns = line as NSString
            if let re = tagRegex, let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                tagged = true
                let tag = ns.substring(with: m.range(at: 1))
                let f = field(ns.substring(with: m.range(at: 3)))
                if tag == "Q" {
                    if var existing = q { existing.d += " " + f.d; existing.s = (existing.s + " " + f.s).trimmed; q = existing } else { q = f }
                    last = .q
                } else if tag.hasPrefix("PART") {
                    var label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).trimmed : ""
                    label = label.rx(#"^[(\[]+|[.)\]]+$"#, "")
                    parts.append(Part(label: label, p: (f.d.isEmpty && f.s.isEmpty) ? nil : f, w: [], a: nil))
                    last = .p(parts.count - 1)
                } else if tag == "W" {
                    if parts.isEmpty { parts.append(Part(label: "", p: nil, w: [], a: nil)) }
                    parts[parts.count - 1].w.append(f)
                    last = .w(parts.count - 1, parts[parts.count - 1].w.count - 1)
                } else {
                    if parts.isEmpty || parts[parts.count - 1].a != nil { parts.append(Part(label: "", p: nil, w: [], a: nil)) }
                    parts[parts.count - 1].a = f
                    last = .a(parts.count - 1)
                }
            } else if !line.trimmed.isEmpty {
                switch last {
                case .none: break
                case .q: if var f = q { append(&f, line); q = f }
                case .p(let i): if var f = parts[i].p { append(&f, line); parts[i].p = f }
                case .w(let i, let j): var f = parts[i].w[j]; append(&f, line); parts[i].w[j] = f
                case .a(let i): if var f = parts[i].a { append(&f, line); parts[i].a = f }
                }
            }
        }
        if !tagged && done && !text.trimmed.isEmpty {
            parts.append(Part(label: "", p: nil, w: [], a: Field(d: text.trimmed, s: "")))
        }
        func fix(_ f: Field?) -> Field? {
            guard var f else { return nil }
            if f.s.isEmpty { f.s = Speech.toSpeech(f.d) }
            return f
        }
        out.q = fix(q)
        out.parts = parts.map { p in
            Part(label: p.label, p: fix(p.p), w: p.w.compactMap { fix($0) }, a: fix(p.a))
        }
        return out
    }
}

// MARK: - Prompt

enum Prompt {
    static func build(extra: String, imageCount: Int) -> String {
        var lines = [
            "You are Readout, a phone camera assistant. The image is a photo of something with text in it: a worksheet, a textbook, a screen, a whiteboard, a sign, a label.",
            "The person listens to your reply read aloud and writes it down by hand, so the spoken text must be easy to copy."
        ]
        if imageCount > 1 {
            lines.append("Image 1 is the whole view. Image 2 is a sharper close-up of the area the person framed. Use the close-up to read small text, subscripts and diagram labels, and the whole view for context.")
        }
        lines += [
            "",
            "What to do:",
            "- A problem or exercise: solve it. For multiple choice, give the letter and the option.",
            "- A problem with parts (a, b, c or 1, 2, 3): handle every part, in order.",
            "- Several separate numbered problems fully in view: treat each one as a part, labeled with its number.",
            "- A prompt or instruction: do it, briefly.",
            "- Text in another language: the answer is the English translation.",
            "- Plain text with no question (a sign, a label, a paragraph): the answer says what it means in one or two sentences.",
            "Read diagrams carefully: labels, values, units, directions and which parts connect. Be correct first, then brief. Check your arithmetic. Ignore background clutter and text cut off at the edges.",
            "",
            "Reply format. One item per line and nothing else: no blank lines, no markdown. Each line is: TAG: display text || spoken text",
            "- display text is shown on screen. Write math in \\( \\) and money as \\$. Write absolute value and magnitude as \\lvert x \\rvert or \\lVert v \\rVert, never as bare | bars, so a line never has two | in a row except the divider.",
            "- spoken text is read aloud for dictation: plain words only, never LaTeX, backslashes, braces or | bars. Say math the way a teacher dictates it, for example \"x equals negative 3 over 4\", \"2 x squared plus 5 x\", \"the square root of 2, all over 2\". Say subscripts with sub, like \"2 I sub 1 minus 3 I sub 2\". Keep every term in the same order as the display.",
            "",
            "Tags, in this order:",
            "Q: the question or the shared instructions, copied faithfully. Leave it out only if there is no shared text.",
            "PART <label>: the text of one part, using the label printed on the page (a, b, 1, 2, ii). Leave PART lines out for a single problem with no parts.",
            "W: one short line of worked steps for the current part, 0 to 5 lines, only what is needed. Always before that part's A.",
            "A: the final answer for the current part, or for the whole problem if there are no parts. Short and direct.",
            "Repeat PART, W, A for each part.",
            "If there is no readable text, reply with exactly: NONE",
            "",
            "Example:",
            "Q: Let \\(f(x) = x^2 \\sin x\\). || Let f of x equal x squared sine x.",
            "PART a: Find \\(f'(x)\\). || Find f prime of x.",
            "W: Product rule: \\((uv)' = u'v + uv'\\) || Use the product rule.",
            "A: \\(f'(x) = 2x\\sin x + x^2\\cos x\\) || f prime of x equals 2 x sine x, plus x squared cosine x.",
            "PART b: Find \\(f'(0)\\). || Find f prime of 0.",
            "W: \\(f'(0) = 0 + 0\\) || Plug in 0. Both terms are 0.",
            "A: \\(f'(0) = 0\\) || f prime of 0 equals 0."
        ]
        let x = String(extra.trimmed.prefix(600))
        if !x.isEmpty {
            lines += ["", "Standing preferences from the person. Follow them unless they break the reply format:", x]
        }
        return lines.joined(separator: "\n")
    }
}
