// Runs one model pass over a PNG of a canvas and prints the edits, without needing the iPad.
//
//   ANTHROPIC_API_KEY=... swift run padmodel canvas.png [--model claude-haiku-5-5] [--effort low] [--instructions "..."]
//
// Handy for trying a prompt change or a different model against a saved snapshot.

import Foundation
import ScratchKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Width and height from a PNG's IHDR chunk, which always sits at bytes 16..<24.
func pngSize(_ data: Data) -> CGSize? {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
    func bigEndian(at offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    return CGSize(width: bigEndian(at: 16), height: bigEndian(at: 20))
}

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var paths: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") {
        guard !arguments.isEmpty else { fail("Missing value for \(argument)") }
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else {
        paths.append(argument)
    }
}

guard let path = paths.first else {
    fail("usage: padmodel <canvas.png> [--model <id>] [--effort low|medium|high] [--instructions <text>]")
}
guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
    fail("Set ANTHROPIC_API_KEY first.")
}
guard let png = FileManager.default.contents(atPath: path), let size = pngSize(png) else {
    fail("\(path) is not a readable PNG.")
}
guard let effort = ClaudeModel.Effort(rawValue: options["effort"] ?? "low") else {
    fail("--effort must be low, medium or high.")
}

let model = ClaudeModel(apiKey: apiKey, model: options["model"] ?? ClaudeModelInfo.fastest.id, effort: effort)
let input = ModelInput(imagePNG: png, imageSize: size, diagram: Diagram(), instructions: options["instructions"] ?? "")

let clock = ContinuousClock()
let started = clock.now
do {
    let output = try await model.edit(input)
    let elapsed = started.duration(to: clock.now)
    print("\(model.model) answered in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"
        + " (\(output.inputTokens ?? 0) tokens in, \(output.outputTokens ?? 0) out)")
    if output.ops.isEmpty { print("No edits.") }
    for op in output.ops {
        switch op {
        case .node(let node):
            let f = node.frame
            print("node   \(node.id)  \(node.shape.rawValue)  at (\(Int(f.minX)), \(Int(f.minY)))  \(Int(f.width))×\(Int(f.height))"
                + "  \"\(node.label)\"  \(node.color.rawValue)")
        case .edge(let edge):
            print("edge   \(edge.id)  \(edge.from) -> \(edge.to)  \(edge.style.rawValue)  \"\(edge.label)\"")
        case .delete(let id):
            print("delete \(id)")
        case .erase(let r):
            print("erase  at (\(Int(r.minX)), \(Int(r.minY)))  \(Int(r.width))×\(Int(r.height))")
        }
    }
} catch {
    fail("Failed: \(error.localizedDescription)")
}
