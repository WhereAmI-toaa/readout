import SwiftUI
import WebKit

/// The question, each part and its answer, with real math typesetting (MathJax, bundled in the app).
struct AnswerCard: UIViewRepresentable {
    var entry: Entry
    var final: Bool
    var working: Bool
    var quiet: String?
    var highlight: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "card", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        let payload: [String: Any] = [
            "entry": Self.json(entry),
            "final": final,
            "working": working,
            "quiet": quiet ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           var js = String(data: data, encoding: .utf8) {
            js = js.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            if js != c.lastPayload {
                c.lastPayload = js
                c.run("render(\(js))")
            }
        }
        let h = highlight.map(String.init) ?? "null"
        if h != c.lastHighlight {
            c.lastHighlight = h
            c.run("highlight(\(h))")
        }
    }

    static func json(_ e: Entry) -> [String: Any] {
        func f(_ x: Field?) -> Any { x.map { ["d": $0.d, "s": $0.s] } ?? NSNull() }
        return [
            "q": f(e.q),
            "parts": e.parts.map { p in
                ["label": p.label, "p": f(p.p), "w": p.w.map { ["d": $0.d] }, "a": f(p.a)] as [String: Any]
            }
        ]
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var loaded = false
        var queue: [String] = []
        var lastPayload = ""
        var lastHighlight = ""

        func run(_ js: String) {
            if loaded { web?.evaluateJavaScript(js, completionHandler: nil) } else { queue.append(js) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            let q = queue
            queue = []
            for js in q { webView.evaluateJavaScript(js, completionHandler: nil) }
        }
    }
}
