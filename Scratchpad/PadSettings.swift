import Foundation
import Observation
import ScratchKit
import Security
import UIKit

/// User-adjustable settings. Everything persists in UserDefaults except the API key, which lives in the keychain.
@MainActor
@Observable
final class PadSettings {
    var apiKey: String {
        didSet { Keychain.set(apiKey, for: Self.apiKeyAccount) }
    }
    var modelID: String {
        didSet { defaults.set(modelID, forKey: "modelID") }
    }
    var effort: ClaudeModel.Effort {
        didSet { defaults.set(effort.rawValue, forKey: "effort") }
    }
    /// How long the pencil must rest before the model takes a look.
    var settleSeconds: Double {
        didSet { defaults.set(settleSeconds, forKey: "settleSeconds") }
    }
    /// Free-text guidance sent along with every pass.
    var instructions: String {
        didSet { defaults.set(instructions, forKey: "instructions") }
    }
    /// The pen's colour.
    var penColor: InkColor {
        didSet { defaults.set(penColor.rawValue, forKey: "penColor") }
    }
    /// The highlighter's colour. Each drawing tool remembers its own.
    var highlighterColor: InkColor {
        didSet { defaults.set(highlighterColor.rawValue, forKey: "highlighterColor") }
    }
    /// Stroke widths in points, one per drawing tool.
    var penWidth: Double {
        didSet { defaults.set(penWidth, forKey: "penWidth") }
    }
    var highlighterWidth: Double {
        didSet { defaults.set(highlighterWidth, forKey: "highlighterWidth") }
    }
    /// The widths each tool offers, thinnest first.
    static let penWidths: [Double] = [2, 4, 7, 11]
    static let highlighterWidths: [Double] = [10, 18, 28, 40]

    /// When on, a finger draws and erases like the Pencil. When off, only the Pencil does, and a
    /// finger moves shapes instead.
    var fingerDraws: Bool {
        didSet { defaults.set(fingerDraws, forKey: "fingerDraws") }
    }
    var loopEnabled: Bool {
        didSet { defaults.set(loopEnabled, forKey: "loopEnabled") }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let apiKeyAccount = "anthropic-api-key"

    init() {
        apiKey = Keychain.get(Self.apiKeyAccount)
        let storedModel = defaults.string(forKey: "modelID")
        modelID = storedModel.flatMap(ClaudeModelInfo.named)?.id ?? ClaudeModelInfo.fastest.id
        effort = defaults.string(forKey: "effort").flatMap(ClaudeModel.Effort.init) ?? .low
        penColor = defaults.string(forKey: "penColor").flatMap(InkColor.init) ?? .ink
        highlighterColor = defaults.string(forKey: "highlighterColor").flatMap(InkColor.init) ?? .yellow
        // Fall back to the default if nothing is stored, or the stored width is no longer offered.
        let storedPen = UserDefaults.standard.double(forKey: "penWidth")
        let storedHighlighter = UserDefaults.standard.double(forKey: "highlighterWidth")
        penWidth = Self.penWidths.contains(storedPen) ? storedPen : 4
        highlighterWidth = Self.highlighterWidths.contains(storedHighlighter) ? storedHighlighter : 18
        // Read through the typed accessors, so a launch argument such as `-fingerDraws NO` (which
        // arrives as a string) overrides the stored value.
        settleSeconds = defaults.object(forKey: "settleSeconds") == nil ? 0.5 : defaults.double(forKey: "settleSeconds")
        instructions = defaults.string(forKey: "instructions") ?? ""
        // On by default: a canvas that ignores your finger looks broken until you find the setting.
        fingerDraws = defaults.object(forKey: "fingerDraws") == nil ? true : defaults.bool(forKey: "fingerDraws")
        loopEnabled = defaults.object(forKey: "loopEnabled") == nil ? true : defaults.bool(forKey: "loopEnabled")
    }

}

/// A colour the pen or the highlighter can draw in.
enum InkColor: String, CaseIterable, Identifiable {
    case ink, gray, red, orange, yellow, green, blue, purple, pink

    var id: String { rawValue }

    /// What the pen offers: dark, saturated colours that read as line work.
    static let penChoices: [InkColor] = [.ink, .gray, .red, .orange, .green, .blue, .purple]
    /// What the highlighter offers: bright colours that text stays legible under.
    static let highlighterChoices: [InkColor] = [.yellow, .green, .blue, .pink, .orange, .purple]

    var name: String {
        self == .ink ? "Black" : rawValue.capitalized
    }

    var uiColor: UIColor {
        switch self {
        // Plain black is special: PencilKit shows it as white ink in Dark Mode.
        case .ink: .black
        case .gray: .systemGray
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }
}

/// A minimal wrapper for string secrets in the keychain.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "scratchpad"

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func get(_ account: String) -> String {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        let query = query(account)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
