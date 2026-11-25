import CoreGraphics
import Foundation
import Testing
@testable import ScratchKit

private func box(_ id: String, x: CGFloat = 0, y: CGFloat = 0, label: String = "") -> Node {
    Node(id: id, shape: .rect, frame: CGRect(x: x, y: y, width: 100, height: 60), label: label)
}

@Suite struct EditOpDecoding {
    @Test func decodesEveryOpKind() throws {
        let json = """
        {"ops":[
          {"op":"node","id":"n1","shape":"ellipse","x":10,"y":20,"w":100,"h":50,"label":"API","color":"blue"},
          {"op":"edge","id":"e1","from":"n1","to":"n2","label":"calls","style":"dashed"},
          {"op":"delete","id":"n9"},
          {"op":"erase","x":1,"y":2,"w":3,"h":4}
        ]}
        """
        let batch = try JSONDecoder().decode(EditBatch.self, from: Data(json.utf8))
        #expect(batch.ops == [
            .node(Node(id: "n1", shape: .ellipse, frame: CGRect(x: 10, y: 20, width: 100, height: 50), label: "API", color: .blue)),
            .edge(Edge(id: "e1", from: "n1", to: "n2", label: "calls", style: .dashed)),
            .delete(id: "n9"),
            .erase(CGRect(x: 1, y: 2, width: 3, height: 4)),
        ])
    }

    @Test func dropsOnlyTheMalformedOp() throws {
        let json = """
        {"ops":[
          {"op":"teleport","id":"n1"},
          {"op":"node","id":"n1","shape":"hexagon","x":0,"y":0,"w":1,"h":1,"label":"","color":"default"},
          {"op":"delete","id":"n2"}
        ]}
        """
        let batch = try JSONDecoder().decode(EditBatch.self, from: Data(json.utf8))
        #expect(batch.ops == [.delete(id: "n2")])
    }

    @Test func normalisesNegativeSizes() throws {
        let json = #"{"ops":[{"op":"erase","x":50,"y":50,"w":-20,"h":-10}]}"#
        let batch = try JSONDecoder().decode(EditBatch.self, from: Data(json.utf8))
        #expect(batch.ops == [.erase(CGRect(x: 30, y: 40, width: 20, height: 10))])
    }

    @Test func scalesGeometryButNotReferences() {
        let node = EditOp.node(box("n1", x: 10, y: 20)).scaled(by: 2)
        #expect(node == .node(Node(id: "n1", shape: .rect, frame: CGRect(x: 20, y: 40, width: 200, height: 120))))
        let edge = EditOp.edge(Edge(id: "e1", from: "a", to: "b"))
        #expect(edge.scaled(by: 2) == edge)
    }
}

@Suite struct Merging {
    @Test func buildsADiagramFromOneBatch() {
        // The edge comes before the nodes it joins, which a model is free to do.
        let result = Diagram().merging([
            .edge(Edge(id: "e1", from: "n1", to: "n2")),
            .node(box("n1")),
            .node(box("n2", x: 300)),
            .erase(CGRect(x: 0, y: 0, width: 500, height: 100)),
        ], base: Diagram())

        #expect(result.diagram.nodes.map(\.id) == ["n1", "n2"])
        #expect(result.diagram.edges.map(\.id) == ["e1"])
        #expect(result.eraseRegions == [CGRect(x: 0, y: 0, width: 500, height: 100)])
        #expect(result.appliedCount == 4)
    }

    @Test func replacesANodeInPlace() {
        let base = Diagram(nodes: [box("n1"), box("n2", x: 300)])
        let result = base.merging([.node(box("n1", label: "API"))], base: base)
        #expect(result.diagram.nodes.map(\.id) == ["n1", "n2"])
        #expect(result.diagram.node("n1")?.label == "API")
    }

    @Test func theUsersChangeBeatsALateAnswer() {
        let base = Diagram(nodes: [box("n1"), box("n2", x: 300)])
        var current = base
        current.nodes[0].frame.origin.x = 500 // dragged while the pass was in flight

        let result = current.merging([
            .node(box("n1", label: "stale")),
            .node(box("n2", x: 300, label: "fresh")),
        ], base: base)

        #expect(result.diagram.node("n1") == current.node("n1"))
        #expect(result.diagram.node("n2")?.label == "fresh")
        #expect(result.appliedCount == 1)
    }

    @Test func doesNotResurrectOrDeleteWhatTheUserChanged() {
        let base = Diagram(nodes: [box("n1"), box("n2", x: 300)])
        var current = base
        current.nodes.removeFirst() // n1 undone away mid-flight
        current.nodes[0].label = "edited"

        let result = current.merging([.node(box("n1", label: "back")), .delete(id: "n2")], base: base)
        #expect(result.diagram == current)
        #expect(result.appliedCount == 0)
    }

    @Test func deletingANodeTakesItsEdges() {
        let base = Diagram(
            nodes: [box("n1"), box("n2", x: 300), box("n3", x: 600)],
            edges: [Edge(id: "e1", from: "n1", to: "n2"), Edge(id: "e2", from: "n2", to: "n3")]
        )
        let result = base.merging([.delete(id: "n1")], base: base)
        #expect(result.diagram.nodes.map(\.id) == ["n2", "n3"])
        #expect(result.diagram.edges.map(\.id) == ["e2"])
    }

    @Test func dropsEdgesThatCannotExist() {
        let base = Diagram(nodes: [box("n1")])
        let result = base.merging([
            .edge(Edge(id: "e1", from: "n1", to: "ghost")),
            .edge(Edge(id: "e2", from: "n1", to: "n1")),
            .edge(Edge(id: "n1", from: "n1", to: "n1")),
        ], base: base)
        #expect(result.diagram == base)
    }

    @Test func enforcesAMinimumNodeSize() {
        let tiny = Node(id: "n1", shape: .rect, frame: CGRect(x: 0, y: 0, width: 0, height: 2))
        let result = Diagram().merging([.node(tiny)], base: Diagram())
        #expect(result.diagram.node("n1")?.frame.size == CGSize(width: 8, height: 8))
    }
}

@Suite struct InkErasing {
    let region = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func takesInkInsideTheRegion() {
        #expect(InkErasure.covers(strokeBounds: CGRect(x: 120, y: 120, width: 50, height: 30), region: region))
    }

    @Test func forgivesARegionThatIsSlightlyShy() {
        #expect(InkErasure.covers(strokeBounds: CGRect(x: 90, y: 95, width: 215, height: 110), region: region))
    }

    @Test func sparesAStrokeThatOnlyPassesThrough() {
        // An arrow that starts in the box and runs far out of it.
        #expect(!InkErasure.covers(strokeBounds: CGRect(x: 280, y: 140, width: 300, height: 10), region: region))
    }

    @Test func sparesInkElsewhere() {
        #expect(!InkErasure.covers(strokeBounds: CGRect(x: 400, y: 400, width: 50, height: 50), region: region))
    }

    @Test func handlesADot() {
        #expect(InkErasure.covers(strokeBounds: CGRect(x: 150, y: 150, width: 0, height: 0), region: region))
        #expect(!InkErasure.covers(strokeBounds: CGRect(x: 50, y: 50, width: 0, height: 0), region: region))
    }
}

@Suite struct EdgeGeometry {
    @Test func rectanglesMeetAtTheirSides() throws {
        let a = box("a")
        let b = box("b", x: 300)
        let segment = try #require(Geometry.segment(from: a, to: b, gap: 0))
        #expect(segment.start == CGPoint(x: 100, y: 30))
        #expect(segment.end == CGPoint(x: 300, y: 30))
    }

    @Test func ellipseAndDiamondUseTheirOwnOutlines() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGPoint(x: 150, y: 150) // straight down the diagonal
        let ellipse = try #require(Geometry.boundaryPoint(of: Node(id: "a", shape: .ellipse, frame: frame), toward: target))
        let diamond = try #require(Geometry.boundaryPoint(of: Node(id: "a", shape: .diamond, frame: frame), toward: target))
        let rect = try #require(Geometry.boundaryPoint(of: Node(id: "a", shape: .rect, frame: frame), toward: target))

        #expect(abs(ellipse.x - (50 + 50 / 2.0.squareRoot())) < 0.001)
        #expect(abs(diamond.x - 75) < 0.001)
        #expect(abs(rect.x - 100) < 0.001)
    }

    @Test func overlappingNodesHaveNoVisibleEdge() {
        #expect(Geometry.segment(from: box("a"), to: box("b", x: 50)) == nil)
        #expect(Geometry.segment(from: box("a"), to: box("b")) == nil)
    }
}

@Suite struct Erasing {
    let diagram = Diagram(
        nodes: [
            Node(id: "box", shape: .rect, frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
            Node(id: "oval", shape: .ellipse, frame: CGRect(x: 400, y: 0, width: 200, height: 100)),
            Node(id: "note", shape: .text, frame: CGRect(x: 0, y: 300, width: 100, height: 30), label: "hi"),
        ],
        edges: [Edge(id: "link", from: "box", to: "oval")]
    )

    @Test func hitsOutlinesButNotInteriors() {
        #expect(diagram.elementID(touchedAt: CGPoint(x: 100, y: 3), tolerance: 10) == "box")
        #expect(diagram.elementID(touchedAt: CGPoint(x: 100, y: 50), tolerance: 10) == nil)
        #expect(diagram.elementID(touchedAt: CGPoint(x: 600, y: 50), tolerance: 10) == "oval")
        // The corner of the oval's bounding box is well away from its outline.
        #expect(diagram.elementID(touchedAt: CGPoint(x: 402, y: 2), tolerance: 10) == nil)
        #expect(diagram.elementID(touchedAt: CGPoint(x: 500, y: 50), tolerance: 10) == nil)
    }

    @Test func hitsTextAnywhereAndEdgesAlongTheirLength() {
        #expect(diagram.elementID(touchedAt: CGPoint(x: 50, y: 315), tolerance: 10) == "note")
        #expect(diagram.elementID(touchedAt: CGPoint(x: 300, y: 55), tolerance: 10) == "link")
        #expect(diagram.elementID(touchedAt: CGPoint(x: 300, y: 90), tolerance: 10) == nil)
    }

    @Test func removingANodeRemovesItsEdges() {
        var copy = diagram
        let removed = copy.remove("box")
        #expect(removed)
        #expect(copy.nodes.map(\.id) == ["oval", "note"])
        #expect(copy.edges.isEmpty)
        let removedAgain = copy.remove("box")
        #expect(!removedAgain)
    }
}

@Suite struct DiagramBasics {
    @Test func offersTheLowestUnusedIDs() {
        let diagram = Diagram(nodes: [box("n1"), box("n3")], edges: [Edge(id: "e1", from: "n1", to: "n3")])
        #expect(diagram.freeIDs(prefix: "n", count: 3) == ["n2", "n4", "n5"])
        #expect(diagram.freeIDs(prefix: "e", count: 2) == ["e2", "e3"])
    }

    @Test func hitTestsTheTopmostNode() {
        let diagram = Diagram(nodes: [box("under"), box("over", x: 50)])
        #expect(diagram.node(at: CGPoint(x: 75, y: 30))?.id == "over")
        #expect(diagram.node(at: CGPoint(x: 10, y: 30))?.id == "under")
        #expect(diagram.node(at: CGPoint(x: 400, y: 30)) == nil)
        #expect(diagram.node(at: CGPoint(x: 155, y: 30), slop: 10)?.id == "over")
    }
}
