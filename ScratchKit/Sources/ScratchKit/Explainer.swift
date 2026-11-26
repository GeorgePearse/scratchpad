import Foundation

/// Explains a picture of part of the canvas in plain words.
public protocol RegionExplainer: Sendable {
    func explain(imagePNG: Data) async throws -> String
}

/// Asks Claude to explain a region the user has selected.
public struct ClaudeExplainer: RegionExplainer {
    public var apiKey: String
    public var model: String
    public var effort: ClaudeModel.Effort
    var transport: ClaudeModel.Transport

    public init(
        apiKey: String,
        model: String = ClaudeModelInfo.fastest.id,
        effort: ClaudeModel.Effort = .low,
        transport: @escaping ClaudeModel.Transport = ClaudeModel.urlSessionTransport
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.transport = transport
    }

    public static let system = """
    The user is studying something on a large canvas: a page of a document, a diagram, their own \
    handwriting. They have dragged a box around one part of it and want it explained. You are sent \
    a picture of exactly that part, and your reply is pasted onto the canvas beside it.

    Explain what the selection says or shows, for a reader who is new to it: what it is, how to \
    read it, and why it matters. Define any term a newcomer would stumble on. Where it helps, give \
    one small concrete example. If the selection is cut off mid-sentence or mid-figure, explain \
    what is visible and say what is missing. If there is almost nothing in it, say so in a sentence.

    Write plain text only, since the canvas cannot render Markdown: no headings, bullets, asterisks \
    or code fences. Use at most two short paragraphs and about 110 words. Start with the \
    explanation itself.
    """

    public func explain(imagePNG: Data) async throws -> String {
        let request = try makeRequest(imagePNG: imagePNG)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code != .cancelled {
            throw ModelError.unavailable(message: error.localizedDescription, retryAfter: nil)
        }
        return try ClaudeModel.replyText(data, response: response).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeRequest(imagePNG: Data) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Self.system,
            "output_config": ["effort": effort.rawValue],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": ["type": "base64", "media_type": "image/png", "data": imagePNG.base64EncodedString()],
                    ],
                    ["type": "text", "text": "Explain this selection."],
                ],
            ]],
        ]
        var request = URLRequest(url: ClaudeModel.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if ClaudeModelInfo.named(model)?.serverFallbacks == true {
            body["fallbacks"] = "default"
            request.setValue(ClaudeModel.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public enum TextLayout {
    /// Breaks text into lines of at most `width` characters, keeping paragraph breaks as blank lines.
    public static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.isEmpty {
                // Collapse runs of blank lines to one.
                if index > 0, lines.last != "" { lines.append("") }
                continue
            }
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    lines.append(line)
                    line = String(word)
                }
            }
            lines.append(line)
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}
