import Foundation

/// The prompt and reply format shared by language-model backends.
public enum Prompt {
    public static let system = """
    You are the editing engine behind a live diagram scratch pad on an iPad. The user draws with an \
    Apple Pencil. Each time they pause, you are sent a picture of the canvas and you reply with edits, \
    which are applied immediately. You will be called again after their next stroke, so a reply only \
    needs to deal with what is ready now.

    ## What you are looking at

    The image is the whole canvas. It holds two kinds of marks:

    - Clean elements: shapes, connectors and text that already exist as structured objects. Each one \
    is listed in the JSON you are given, and has its id printed beside it in small magenta type. Those \
    magenta tags are only in your copy of the image; the user does not see them.
    - Ink: freehand pencil strokes, which is everything else. Ink is how the user talks to you: a \
    rough shape, some handwriting, an arrow, a scribble through something, a written instruction.

    Coordinates are image pixels with the origin at the top left, x to the right and y down.

    ## What to do

    Turn finished ink into clean elements, carry out what the ink asks for, and erase the ink you used.

    - A hand-drawn box, oval or diamond becomes a node of that shape, at the place and size it was \
    drawn. Handwriting inside it becomes its label.
    - Handwriting on its own becomes a "text" node. Handwriting written in or on an existing node \
    becomes that node's label.
    - A line or arrow drawn from one node to another becomes an edge. Use style "arrow" when it has \
    an arrowhead (the head points at `to`), "line" when it has none, and "dashed" for a dashed stroke. \
    Handwriting beside it becomes the edge's label.
    - A scribble or cross through an element deletes it.
    - Any other mark or written instruction ("make this red", an arrow showing where something \
    should move, a bracket with "align") means what it evidently means. Do it with the ops you have.

    ## The ops

    - `node` creates a node, or replaces the node that already has that id. To change an existing \
    node, send it again under the same id with every field filled in, changed or not. Give new nodes \
    one of the unused ids you are offered. `label` is "" for no label; `color` is "default" unless \
    the user asked for a colour.
    - `edge` works the same way for connectors. `from` and `to` are node ids, and may be nodes \
    created earlier in the same reply.
    - `delete` removes a node or an edge by id. Deleting a node removes its edges too.
    - `erase` removes the ink strokes that lie mostly inside a rectangle. It never affects clean \
    elements. Whenever you act on some ink, erase it in the same reply, or it stays on the canvas and \
    you will be shown it again. Keep the rectangle snug around the ink you are using up, because \
    any other ink inside it goes too.

    ## Judgement

    - Wait for ink that looks unfinished: a half-closed shape, a word that trails off, an arrow that \
    has not reached anything yet. Leave it alone and return no ops for it; you will see it again once \
    the user has added more. Acting a moment late costs nothing, while acting early pulls ink out from \
    under the pencil.
    - Leave alone what the user did not touch. Do not move, resize, recolour or relabel existing \
    elements unless the ink asks for it.
    - Stay faithful to what was drawn. Small tidying is welcome (squaring up a shape, lining up \
    things that were clearly meant to line up, matching sizes that were clearly meant to match), but \
    the layout is the user's.
    - Read handwriting as written, keeping the user's capitalisation. If a word is illegible, wait \
    rather than guess.
    - Sketches and doodles that are not diagram elements stay as ink.
    - Often there is nothing to do. An empty list of ops is then the right answer.

    Reply with the JSON object only.
    """

    /// The per-pass text that accompanies the image.
    public static func userText(for input: ModelInput) -> String {
        var lines: [String] = []
        lines.append("The canvas image is \(Int(input.imageSize.width))×\(Int(input.imageSize.height)) px.")
        lines.append("")
        if input.diagram.isEmpty {
            lines.append("There are no clean elements on the canvas yet; every mark in the image is ink.")
        } else {
            lines.append("Clean elements on the canvas:")
            lines.append(sceneJSON(input.diagram))
        }
        let nodeIDs = input.diagram.freeIDs(prefix: "n", count: 6).joined(separator: ", ")
        let edgeIDs = input.diagram.freeIDs(prefix: "e", count: 6).joined(separator: ", ")
        lines.append("")
        lines.append("Unused ids for new nodes: \(nodeIDs). Unused ids for new edges: \(edgeIDs).")

        let instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            lines.append("")
            lines.append("Standing instructions from the user, which apply to every reply:")
            lines.append(instructions)
        }
        return lines.joined(separator: "\n")
    }

    /// The clean elements as compact JSON with whole-pixel coordinates.
    public static func sceneJSON(_ diagram: Diagram) -> String {
        struct NodeDTO: Encodable {
            let id: String, shape: String, x: Int, y: Int, w: Int, h: Int, label: String, color: String
        }
        struct EdgeDTO: Encodable {
            let id: String, from: String, to: String, label: String, style: String
        }
        struct Scene: Encodable {
            let nodes: [NodeDTO]
            let edges: [EdgeDTO]
        }
        let scene = Scene(
            nodes: diagram.nodes.map {
                NodeDTO(
                    id: $0.id, shape: $0.shape.rawValue,
                    x: Int($0.frame.minX.rounded()), y: Int($0.frame.minY.rounded()),
                    w: Int($0.frame.width.rounded()), h: Int($0.frame.height.rounded()),
                    label: $0.label, color: $0.color.rawValue
                )
            },
            edges: diagram.edges.map {
                EdgeDTO(id: $0.id, from: $0.from, to: $0.to, label: $0.label, style: $0.style.rawValue)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(scene) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON Schema for the reply. Every object is closed and every field required, which is what
    /// constrained decoding needs; optionality is expressed with "" and "default" instead.
    public static func outputSchema() -> [String: Any] {
        func object(_ fields: [(String, [String: Any])]) -> [String: Any] {
            [
                "type": "object",
                "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1) }),
                "required": fields.map(\.0),
                "additionalProperties": false,
            ]
        }
        func op(_ name: String) -> (String, [String: Any]) { ("op", ["const": name]) }
        let string: [String: Any] = ["type": "string"]
        let pixels: [String: Any] = ["type": "integer"]
        let rect: [(String, [String: Any])] = [("x", pixels), ("y", pixels), ("w", pixels), ("h", pixels)]

        let node = object(
            [op("node"), ("id", string), ("shape", ["enum": Node.Shape.allCases.map(\.rawValue)])]
                + rect
                + [("label", string), ("color", ["enum": NodeColor.allCases.map(\.rawValue)])]
        )
        let edge = object([
            op("edge"), ("id", string), ("from", string), ("to", string), ("label", string),
            ("style", ["enum": Edge.Style.allCases.map(\.rawValue)]),
        ])
        let delete = object([op("delete"), ("id", string)])
        let erase = object([op("erase")] + rect)

        return object([
            ("ops", ["type": "array", "items": ["anyOf": [node, edge, delete, erase]]]),
        ])
    }
}
