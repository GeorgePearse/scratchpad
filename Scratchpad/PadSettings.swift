import Foundation
import Observation
import ScratchKit
import Security

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
        // Read through the typed accessors, so a launch argument such as `-fingerDraws NO` (which
        // arrives as a string) overrides the stored value.
        settleSeconds = defaults.object(forKey: "settleSeconds") == nil ? 0.5 : defaults.double(forKey: "settleSeconds")
        instructions = defaults.string(forKey: "instructions") ?? ""
        // On by default: a canvas that ignores your finger looks broken until you find the setting.
        fingerDraws = defaults.object(forKey: "fingerDraws") == nil ? true : defaults.bool(forKey: "fingerDraws")
        loopEnabled = defaults.object(forKey: "loopEnabled") == nil ? true : defaults.bool(forKey: "loopEnabled")
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
