import Foundation

/// A Claude model the pad can run on.
public struct ClaudeModelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let note: String
    /// Whether the API can re-run a declined request on a fallback model for this model.
    let serverFallbacks: Bool

    public static let all: [ClaudeModelInfo] = [
        .init(id: "claude-haiku-5-5", name: "Haiku 5.5", note: "Fastest. Best for a tight loop.", serverFallbacks: false),
        .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5", note: "Slower, reads messy ink better.", serverFallbacks: true),
        .init(id: "claude-opus-5-5", name: "Opus 5.5", note: "Slower still, strongest judgement.", serverFallbacks: true),
        .init(id: "claude-fable-5-2", name: "Fable 5.2", note: "Most capable, slowest and priciest.", serverFallbacks: true),
    ]

    public static let fastest = all[0]

    public static func named(_ id: String) -> ClaudeModelInfo? { all.first { $0.id == id } }
}

/// Runs a pass by sending the snapshot to the Claude Messages API.
public struct ClaudeModel: DiagramModel {
    public enum Effort: String, CaseIterable, Sendable {
        case low, medium, high
    }

    /// Sends a request and returns the body and HTTP response. Swappable for tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public var apiKey: String
    public var model: String
    public var effort: Effort
    var transport: Transport

    public init(
        apiKey: String,
        model: String = ClaudeModelInfo.fastest.id,
        effort: Effort = .low,
        transport: @escaping Transport = ClaudeModel.urlSessionTransport
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.transport = transport
    }

    public static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func edit(_ input: ModelInput) async throws -> ModelOutput {
        let request = try makeRequest(for: input)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError where error.code != .cancelled {
            throw ModelError.unavailable(message: error.localizedDescription, retryAfter: nil)
        }
        return try Self.parse(data, response: response)
    }

    // MARK: Request

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    func makeRequest(for input: ModelInput) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            // Generous on purpose: the cap is shared with the model's thinking, and replies are tiny anyway.
            "max_tokens": 16000,
            "system": [[
                "type": "text",
                "text": Prompt.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "output_config": [
                "effort": effort.rawValue,
                "format": ["type": "json_schema", "schema": Prompt.outputSchema()],
            ],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": input.imagePNG.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": Prompt.userText(for: input)],
                ],
            ]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        // If a safety classifier declines the pass, let the API re-run it on its recommended fallback
        // model rather than hand back a refusal. Haiku has no server-side fallback.
        if ClaudeModelInfo.named(model)?.serverFallbacks == true {
            body["fallbacks"] = "default"
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Response

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        struct StopDetails: Decodable {
            let category: String?
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
        let usage: Usage?
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }
        let error: Detail
    }

    static func parse(_ data: Data, response: HTTPURLResponse) throws -> ModelOutput {
        guard response.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
            let message = detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            switch response.statusCode {
            case 401, 403:
                throw ModelError.unauthorized(message)
            case 408, 409, 429, 500...:
                let seconds = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                throw ModelError.unavailable(message: message, retryAfter: seconds.map { .seconds($0) })
            default:
                throw ModelError.rejected(status: response.statusCode, message: message)
            }
        }

        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw ModelError.malformedReply("The response was not a message.")
        }

        // Check why the model stopped before trusting the content: a refusal or a cut-off reply
        // still comes back as HTTP 200.
        switch reply.stop_reason {
        case "refusal": throw ModelError.refused(category: reply.stop_details?.category)
        case "max_tokens": throw ModelError.truncated
        default: break
        }

        // The reply can open with thinking blocks, so pick text blocks by type rather than position.
        let text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let json = text.data(using: .utf8), !text.isEmpty else {
            throw ModelError.malformedReply("It contained no text.")
        }
        do {
            let batch = try JSONDecoder().decode(EditBatch.self, from: json)
            return ModelOutput(
                ops: batch.ops,
                inputTokens: reply.usage?.input_tokens,
                outputTokens: reply.usage?.output_tokens
            )
        } catch {
            throw ModelError.malformedReply("It was not the expected JSON.")
        }
    }
}
