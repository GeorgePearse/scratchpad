import CoreGraphics
import Foundation

/// Everything a model gets to look at for one pass over the canvas.
///
/// All coordinates are in the pixel space of `imagePNG`, origin top-left.
public struct ModelInput: Sendable {
    /// The whole canvas rendered on white: clean elements (with their ids printed beside them) plus ink.
    public var imagePNG: Data
    /// Size of `imagePNG` in pixels.
    public var imageSize: CGSize
    /// The clean elements that appear in the image.
    public var diagram: Diagram
    /// Free-text guidance from the user that applies to every pass. May be empty.
    public var instructions: String
    /// Ids that are safe to give new elements. When the image shows only part of a larger canvas,
    /// `diagram` does not list everything, so the free ids have to be supplied from outside.
    public var unusedIDs: (nodes: [String], edges: [String])

    public init(
        imagePNG: Data, imageSize: CGSize, diagram: Diagram, instructions: String = "",
        unusedIDs: (nodes: [String], edges: [String])? = nil
    ) {
        self.imagePNG = imagePNG
        self.imageSize = imageSize
        self.diagram = diagram
        self.instructions = instructions
        self.unusedIDs = unusedIDs ?? (diagram.freeIDs(prefix: "n", count: 6), diagram.freeIDs(prefix: "e", count: 6))
    }
}

public struct ModelOutput: Sendable {
    /// Edits to apply, in the same pixel space as the input image.
    public var ops: [EditOp]
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(ops: [EditOp], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.ops = ops
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A visual model that edits the canvas. Implement this to plug in a different model.
///
/// It is called once per pass with a fresh snapshot and keeps no state between passes, so any
/// function from "picture of the canvas" to "list of edits" fits: a hosted VLM, a local detector,
/// a rules engine.
public protocol DiagramModel: Sendable {
    func edit(_ input: ModelInput) async throws -> ModelOutput
}

public enum ModelError: Error, Equatable, Sendable {
    /// The credentials were not accepted. Retrying will not help until they change.
    case unauthorized(String)
    /// The request itself was rejected (a 4xx other than auth or rate limiting).
    case rejected(status: Int, message: String)
    /// Rate limited, overloaded, or unreachable. Worth retrying.
    case unavailable(message: String, retryAfter: Duration?)
    /// The model declined to answer.
    case refused(category: String?)
    /// The reply was cut off before it finished.
    case truncated
    /// The reply arrived but was not the JSON we asked for.
    case malformedReply(String)

    /// Whether the same snapshot is worth sending again after a wait.
    public var isRetryable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Whether the loop should switch itself off, because every further request would fail the same way.
    public var stopsLoop: Bool {
        switch self {
        case .unauthorized, .rejected: return true
        default: return false
        }
    }

    public var retryAfter: Duration? {
        if case .unavailable(_, let wait) = self { return wait }
        return nil
    }
}

extension ModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message): return "API key not accepted. \(message)"
        case .rejected(let status, let message): return "Request rejected (\(status)). \(message)"
        case .unavailable(let message, _): return message
        case .refused(let category): return "The model declined this one" + (category.map { " (\($0))." } ?? ".")
        case .truncated: return "The model's reply was cut off."
        case .malformedReply(let detail): return "Couldn't read the model's reply. \(detail)"
        }
    }
}
