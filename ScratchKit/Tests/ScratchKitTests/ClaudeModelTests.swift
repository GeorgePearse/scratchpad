import CoreGraphics
import Foundation
import Testing
@testable import ScratchKit

private let input = ModelInput(
    imagePNG: Data([1, 2, 3]),
    imageSize: CGSize(width: 1024, height: 768),
    diagram: Diagram(nodes: [Node(id: "n1", shape: .rect, frame: CGRect(x: 10.4, y: 20.6, width: 100, height: 60), label: "API")]),
    instructions: "  Use rounded boxes.  "
)

private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: ClaudeModel.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!
}

/// A model whose transport answers with a canned body.
private func model(_ id: String = "claude-haiku-5-5", status: Int = 200, headers: [String: String] = [:], body: String) -> ClaudeModel {
    ClaudeModel(apiKey: "test-key", model: id) { _ in (Data(body.utf8), response(status, headers: headers)) }
}

private func jsonBody(of request: URLRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody))
    return try #require(object as? [String: Any])
}

@Suite struct ClaudeRequest {
    @Test func sendsTheImageThenTheSceneText() throws {
        let request = try ClaudeModel(apiKey: "test-key", model: "claude-haiku-5-5", effort: .medium).makeRequest(for: input)

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")

        let body = try jsonBody(of: request)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        // Sampling parameters and forced tool choice are rejected by current models; neither may creep in.
        #expect(body["temperature"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["thinking"] == nil)

        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")

        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "AQID")

        let text = try #require(content[1]["text"] as? String)
        #expect(text.contains("1024×768"))
        #expect(text.contains(#""id":"n1""#))
        #expect(text.contains(#""x":10"#) && text.contains(#""y":21"#))
        #expect(text.contains("new nodes: n2, n3"))
        #expect(text.hasSuffix("Use rounded boxes."))
    }

    @Test func asksForServerFallbacksOnlyWhereTheyExist() throws {
        let haiku = try ClaudeModel(apiKey: "k", model: "claude-haiku-5-5").makeRequest(for: input)
        #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try jsonBody(of: haiku)["fallbacks"] == nil)

        for id in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"] {
            let request = try ClaudeModel(apiKey: "k", model: id).makeRequest(for: input)
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
            #expect(try jsonBody(of: request)["fallbacks"] as? String == "default")
        }
    }

    @Test func describesAnEmptyCanvasInWords() {
        var empty = input
        empty.diagram = Diagram()
        empty.instructions = ""
        let text = Prompt.userText(for: empty)
        #expect(text.contains("no clean elements"))
        #expect(!text.contains("Standing instructions"))
    }

    /// Constrained decoding needs every object closed and every property required.
    @Test func schemaIsClosedAllTheWayDown() throws {
        var objects = 0
        func check(_ schema: [String: Any]) throws {
            if schema["type"] as? String == "object" {
                objects += 1
                let properties = try #require(schema["properties"] as? [String: [String: Any]])
                let required = try #require(schema["required"] as? [String])
                #expect(schema["additionalProperties"] as? Bool == false)
                #expect(Set(required) == Set(properties.keys))
                for property in properties.values { try check(property) }
            }
            if let items = schema["items"] as? [String: Any] { try check(items) }
            for branch in schema["anyOf"] as? [[String: Any]] ?? [] { try check(branch) }
        }
        let schema = Prompt.outputSchema()
        try check(schema)
        #expect(objects == 2)
        #expect(JSONSerialization.isValidJSONObject(schema))
    }
}

@Suite struct ClaudeResponse {
    @Test func readsOpsPastALeadingThinkingBlock() async throws {
        let body = #"""
        {"content":[
           {"type":"thinking","thinking":"","signature":"abc"},
           {"type":"text","text":"{\"ops\":[{\"op\":\"delete\",\"id\":\"n1\"}]}"}
         ],
         "stop_reason":"end_turn","usage":{"input_tokens":1500,"output_tokens":20}}
        """#
        let output = try await model(body: body).edit(input)
        #expect(output.ops == [.delete(id: "n1")])
        #expect(output.inputTokens == 1500)
        #expect(output.outputTokens == 20)
    }

    @Test func surfacesARefusalInsteadOfParsingIt() async {
        let body = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"general_harms"}}"#
        await #expect(throws: ModelError.refused(category: "general_harms")) {
            try await model(body: body).edit(input)
        }
    }

    @Test func surfacesATruncatedReply() async {
        let body = #"{"content":[{"type":"text","text":"{\"ops\":[{\"op\":\"del"}],"stop_reason":"max_tokens"}"#
        await #expect(throws: ModelError.truncated) {
            try await model(body: body).edit(input)
        }
    }

    @Test func rejectsTextThatIsNotTheSchema() async {
        let body = #"{"content":[{"type":"text","text":"Sure! Here you go."}],"stop_reason":"end_turn"}"#
        await #expect(throws: ModelError.malformedReply("It was not the expected JSON.")) {
            try await model(body: body).edit(input)
        }
    }

    @Test func mapsHTTPFailuresToWhatTheLoopShouldDo() async {
        let error = #"{"type":"error","error":{"type":"x","message":"nope"}}"#

        await #expect(throws: ModelError.unauthorized("nope")) {
            try await model(status: 401, body: error).edit(input)
        }
        await #expect(throws: ModelError.rejected(status: 400, message: "nope")) {
            try await model(status: 400, body: error).edit(input)
        }
        await #expect(throws: ModelError.unavailable(message: "nope", retryAfter: .seconds(7))) {
            try await model(status: 429, headers: ["retry-after": "7"], body: error).edit(input)
        }
        await #expect(throws: ModelError.unavailable(message: "nope", retryAfter: nil)) {
            try await model(status: 529, body: error).edit(input)
        }
    }

    @Test func treatsANetworkFailureAsRetryable() async {
        let offline = ClaudeModel(apiKey: "k") { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.edit(input)
            Issue.record("Expected a failure")
        } catch {
            #expect((error as? ModelError)?.isRetryable == true)
        }
    }
}

@Suite struct Explaining {
    @Test func sendsTheSelectionAndReturnsPlainText() async throws {
        let body = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"  It is a loss function.\n"}],"stop_reason":"end_turn"}"#
        let explainer = ClaudeExplainer(apiKey: "test-key", model: "claude-opus-5-5") { request in
            let sent = try jsonBody(of: request)
            #expect(sent["model"] as? String == "claude-opus-5-5")
            #expect(sent["fallbacks"] as? String == "default")
            #expect((sent["output_config"] as? [String: Any])?["format"] == nil)
            let content = try #require((sent["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
            #expect(content.first?["type"] as? String == "image")
            return (Data(body.utf8), response(200))
        }
        #expect(try await explainer.explain(imagePNG: Data([1, 2, 3])) == "It is a loss function.")
    }

    @Test func passesFailuresThrough() async {
        let error = #"{"type":"error","error":{"type":"x","message":"credit balance is too low"}}"#
        let explainer = ClaudeExplainer(apiKey: "k") { _ in (Data(error.utf8), response(400)) }
        await #expect(throws: ModelError.rejected(status: 400, message: "credit balance is too low")) {
            try await explainer.explain(imagePNG: Data())
        }
    }

    @Test func wrapsTextAndKeepsParagraphs() {
        let lines = TextLayout.wrap("one two three four\n\n\nfive six", width: 9)
        #expect(lines == ["one two", "three", "four", "", "five six"])
    }
}
