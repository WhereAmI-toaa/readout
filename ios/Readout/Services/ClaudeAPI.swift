import Foundation

struct ClaudeImage {
    let label: String
    let jpeg: Data
}

struct ClaudeError: Error {
    let status: Int
    let message: String

    var friendly: String {
        switch status {
        case 401: return "Anthropic rejected that API key. Paste it again in Settings."
        case 403: return "This API key isn't allowed to use that model. Try another model in Settings."
        case 413: return "The photo was too big to send. Try Standard photo detail in Settings."
        case 429: return "Too many requests in a row. Wait a few seconds and try again."
        case 500...599: return "Claude is overloaded right now. Try again in a moment."
        case -1: return "No connection to Anthropic. Check your internet and try again."
        case 0: return "No answer came back. Try a clearer, closer shot."
        default:
            if message.range(of: "credit|billing|balance", options: [.regularExpression, .caseInsensitive]) != nil {
                return "Your Anthropic account is out of credit. Add some at console.anthropic.com."
            }
            return message.isEmpty ? "The request failed (error \(status)). Try again." : "Anthropic said: \(message)"
        }
    }
}

enum ClaudeAPI {
    /// Streams a reply. `onText` gets the whole reply so far, on a background thread.
    static func stream(key: String, model: String, think: Bool, images: [ClaudeImage], prompt: String,
                       onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var content: [[String: Any]] = []
        for img in images {
            content.append(["type": "text", "text": img.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        var body: [String: Any] = [
            "model": model,
            "max_tokens": think ? 16000 : 2500,
            "stream": true,
            "messages": [["role": "user", "content": content]]
        ]
        if think {
            if model.hasPrefix("claude-haiku") {
                body["thinking"] = ["type": "enabled", "budget_tokens": 6000]
                body["max_tokens"] = 12000
            } else {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": "high"]
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw ClaudeError(status: -1, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 200_000 { break }
            }
            var msg = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let m = err["message"] as? String { msg = m }
            throw ClaudeError(status: status, message: msg)
        }

        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = json.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            if type == "content_block_delta", let delta = ev["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta", let t = delta["text"] as? String {
                text += t
                onText(text)
            } else if type == "error" {
                let m = (ev["error"] as? [String: Any])?["message"] as? String ?? ""
                throw ClaudeError(status: 529, message: m)
            }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ClaudeError(status: 0, message: "") }
        return text
    }
}
