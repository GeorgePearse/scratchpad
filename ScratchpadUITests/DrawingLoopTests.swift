import XCTest

/// Draws on the real canvas and checks that the loop turns ink into shapes.
///
/// The app runs with `-cannedModel YES`, so no network or API key is involved: the canned model
/// answers its first pass with two shapes and a connector in the top half of the canvas, and its
/// second with a third shape below them. Everything else (PencilKit, the loop, merging, erasing,
/// undo) is the real thing.
final class DrawingLoopTests: XCTestCase {
    @MainActor
    func testInkBecomesShapesAndUndoStepsBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-cannedModel", "YES"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "Empty")
        XCTAssertFalse(app.buttons["Undo"].isEnabled)

        // A stroke where the first shape belongs. The model replaces it, so the ink goes.
        draw(on: canvas, from: (0.12, 0.26), to: (0.28, 0.38))
        expect(canvas, toRead: "2 shapes, 1 connector, 0 ink strokes")

        // A stroke somewhere the model has no use for. It answers with a third shape and leaves this ink alone.
        draw(on: canvas, from: (0.10, 0.76), to: (0.30, 0.78))
        expect(canvas, toRead: "3 shapes, 2 connectors, 1 ink stroke")

        // Undo peels back one step at a time: the model's edit, then the stroke that prompted it.
        app.buttons["Undo"].tap()
        expect(canvas, toRead: "2 shapes, 1 connector, 1 ink stroke")
        app.buttons["Undo"].tap()
        expect(canvas, toRead: "2 shapes, 1 connector, 0 ink strokes")

        app.buttons["Clear"].tap()
        expect(canvas, toRead: "Empty")
    }

    @MainActor
    func testSwitchingTheModelOffLeavesInkAlone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-cannedModel", "YES"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "Empty")

        app.buttons["Model"].tap()
        draw(on: canvas, from: (0.12, 0.26), to: (0.28, 0.38))
        expect(canvas, toRead: "0 shapes, 0 connectors, 1 ink stroke")

        // Nothing should happen however long we wait.
        sleep(2)
        XCTAssertEqual(canvas.value as? String, "0 shapes, 0 connectors, 1 ink stroke")

        // Switching back on looks at what is already there.
        app.buttons["Model"].tap()
        expect(canvas, toRead: "2 shapes, 1 connector, 0 ink strokes")
    }

    @MainActor
    func testTheEraserRemovesInk() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-cannedModel", "YES"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "Empty")

        // Model off, so the ink stays put.
        app.buttons["Model"].tap()
        draw(on: canvas, from: (0.20, 0.50), to: (0.60, 0.50))
        expect(canvas, toRead: "0 shapes, 0 connectors, 1 ink stroke")

        // Rub across the stroke with the eraser.
        app.buttons["Eraser"].tap()
        draw(on: canvas, from: (0.40, 0.40), to: (0.40, 0.60))
        expect(canvas, toRead: "Empty")
        XCTAssertTrue(app.buttons["Eraser"].isSelected)

        // And back to the pen to carry on drawing.
        app.buttons["Pen"].tap()
        XCTAssertTrue(app.buttons["Pen"].isSelected)
        draw(on: canvas, from: (0.20, 0.50), to: (0.60, 0.50))
        expect(canvas, toRead: "0 shapes, 0 connectors, 1 ink stroke")
    }

    @MainActor
    func testTheEraserRemovesShapesToo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "3 shapes, 2 connectors, 1 ink stroke", timeout: 20)
        app.buttons["Model"].tap()
        app.buttons["Eraser"].tap()

        // Across the left side of the first box: the box goes, and its connector with it.
        draw(on: canvas, from: (0.05, 0.32), to: (0.15, 0.32))
        expect(canvas, toRead: "2 shapes, 1 connector, 1 ink stroke")

        // Through the middle of the remaining connector, touching neither shape.
        draw(on: canvas, from: (0.50, 0.51), to: (0.64, 0.51))
        expect(canvas, toRead: "2 shapes, 0 connectors, 1 ink stroke")

        // Inside a shape, away from its outline, the eraser leaves it alone.
        draw(on: canvas, from: (0.55, 0.31), to: (0.59, 0.33))
        XCTAssertEqual(canvas.value as? String, "2 shapes, 0 connectors, 1 ink stroke")

        app.buttons["Undo"].tap()
        expect(canvas, toRead: "2 shapes, 1 connector, 1 ink stroke")
    }

    /// On a real iPad only the Pencil draws, which frees a finger to move shapes. The simulator has
    /// no Pencil, so the scripted demo supplies the ink and the test supplies the finger.
    @MainActor
    func testAFingerMovesAShapeWhenOnlyThePencilDraws() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-fingerDraws", "NO"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "3 shapes, 2 connectors, 1 ink stroke", timeout: 20)

        // The first shape sits around (0.20, 0.32). Drag it to an empty patch of canvas.
        let target = (0.82, 0.62)
        XCTAssertFalse(hasMarks(canvas, around: target))
        draw(on: canvas, from: (0.20, 0.32), to: target)

        XCTAssertTrue(hasMarks(canvas, around: target), "The shape should now be under the finger")
        XCTAssertEqual(canvas.value as? String, "3 shapes, 2 connectors, 1 ink stroke", "A finger must not draw")

        app.buttons["Undo"].tap()
        XCTAssertFalse(hasMarks(canvas, around: target), "Undo should put the shape back")
    }

    /// With the pad Pencil-only, a finger on empty canvas pans it, and shapes can still be picked
    /// up afterwards, which checks that touches are mapped through the scrolled view correctly.
    @MainActor
    func testAFingerPansTheCanvas() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES", "-fingerDraws", "NO"]
        app.launch()

        let canvas = app.otherElements["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        expect(canvas, toRead: "3 shapes, 2 connectors, 1 ink stroke", timeout: 20)

        // The first shape is centred on (0.20, 0.32). Pan by (+0.5, +0.2) from an empty spot.
        let landed = (0.70, 0.52)
        XCTAssertFalse(hasMarks(canvas, around: landed))
        draw(on: canvas, from: (0.30, 0.55), to: (0.80, 0.75))
        XCTAssertTrue(hasMarks(canvas, around: landed), "The shape should have moved with the canvas")
        XCTAssertEqual(canvas.value as? String, "3 shapes, 2 connectors, 1 ink stroke")

        // Now pick the shape up where it is on screen and drop it somewhere else.
        let target = (0.85, 0.88)
        XCTAssertFalse(hasMarks(canvas, around: target))
        draw(on: canvas, from: landed, to: target)
        XCTAssertTrue(hasMarks(canvas, around: target), "The shape should follow the finger after a pan")
        XCTAssertFalse(hasMarks(canvas, around: landed))

        // Fit brings everything back on screen without changing the content.
        app.buttons["Show everything"].tap()
        XCTAssertEqual(canvas.value as? String, "3 shapes, 2 connectors, 1 ink stroke")
    }

    // MARK: Helpers

    /// Whether anything is drawn in a small patch of the canvas, judged against its top-left pixel.
    @MainActor
    private func hasMarks(_ canvas: XCUIElement, around center: (Double, Double)) -> Bool {
        guard let image = canvas.screenshot().image.cgImage else { return false }
        let patch = CGRect(
            x: Double(image.width) * (center.0 - 0.04), y: Double(image.height) * (center.1 - 0.015),
            width: Double(image.width) * 0.08, height: Double(image.height) * 0.03
        ).integral
        guard let crop = image.cropping(to: patch) else { return false }

        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let background = Int(pixels[0])
        return stride(from: 0, to: pixels.count, by: 4).contains { abs(Int(pixels[$0]) - background) > 60 }
    }

    @MainActor
    private func draw(on canvas: XCUIElement, from: (Double, Double), to: (Double, Double)) {
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: from.0, dy: from.1))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: to.0, dy: to.1))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func expect(
        _ canvas: XCUIElement, toRead value: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let matches = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: canvas)
        if XCTWaiter().wait(for: [matches], timeout: timeout) != .completed {
            XCTFail("Canvas reads \"\(canvas.value as? String ?? "nil")\", expected \"\(value)\"", file: file, line: line)
        }
    }
}
