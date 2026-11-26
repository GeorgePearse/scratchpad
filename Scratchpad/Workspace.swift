import Foundation
import Observation

/// The set of pads, shown as tabs. Each tab is its own canvas with its own ink, shapes, PDF and
/// undo history, stored in its own folder.
@MainActor
@Observable
final class Workspace {
    struct Tab: Identifiable, Codable, Equatable {
        var id: UUID
        var title: String
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedID: UUID

    let settings = PadSettings()

    @ObservationIgnored private var stores: [UUID: PadStore] = [:]
    @ObservationIgnored private let root: URL

    private struct Index: Codable {
        var tabs: [Tab]
        var selected: UUID
    }

    /// - Parameter scratch: Keep everything in a throwaway folder. The demo and the UI tests use
    ///   this so they never touch real pads.
    init(scratch: Bool = false) {
        let base = scratch
            ? FileManager.default.temporaryDirectory.appending(path: "scratch-\(UUID().uuidString)")
            : URL.applicationSupportDirectory
        root = base.appending(path: "pads")
        selectedID = UUID()

        if let data = try? Data(contentsOf: root.appending(path: "index.json")),
           let index = try? JSONDecoder().decode(Index.self, from: data), !index.tabs.isEmpty {
            tabs = index.tabs
            selectedID = index.tabs.contains { $0.id == index.selected } ? index.selected : index.tabs[0].id
        } else {
            // First run with tabs: the single pad from earlier versions becomes the first tab.
            let first = Tab(id: UUID(), title: "Pad 1")
            let folder = folder(for: first.id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["pad.json", "document.pdf"] {
                try? FileManager.default.moveItem(at: base.appending(path: name), to: folder.appending(path: name))
            }
            tabs = [first]
            selectedID = first.id
            saveIndex()
        }
    }

    /// The pad on screen.
    var current: PadStore { store(for: selectedID) }

    private func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString)
    }

    private func store(for id: UUID) -> PadStore {
        if let store = stores[id] { return store }
        let store = PadStore(id: id, folder: folder(for: id), settings: settings)
        stores[id] = store
        return store
    }

    // MARK: Tabs

    func select(_ id: UUID) {
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        current.saveNow()
        selectedID = id
        // The on/off switch is shared, so bring this pad's loop into line with it.
        current.loop.setEnabled(settings.loopEnabled, lookNow: false)
        saveIndex()
    }

    @discardableResult
    func addTab() -> UUID {
        // The lowest "Pad N" not in use, so closed tabs free their numbers.
        var number = 1
        while tabs.contains(where: { $0.title == "Pad \(number)" }) { number += 1 }
        let tab = Tab(id: UUID(), title: "Pad \(number)")
        tabs.append(tab)
        select(tab.id)
        saveIndex()
        return tab.id
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
        saveIndex()
    }

    /// Whether closing this tab would throw work away.
    func hasContent(_ id: UUID) -> Bool {
        !store(for: id).isBlank
    }

    /// Closes a tab and deletes its pad. The last tab is replaced by an empty one.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 { addTab() }
        if selectedID == id {
            let neighbour = tabs[index == tabs.count - 1 ? index - 1 : index + 1]
            select(neighbour.id)
        }
        tabs.remove(at: index)
        stores[id]?.persists = false
        stores[id] = nil
        try? FileManager.default.removeItem(at: folder(for: id))
        saveIndex()
    }

    // MARK: Saving

    func saveAll() {
        stores.values.forEach { $0.saveNow() }
        saveIndex()
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Index(tabs: tabs, selected: selectedID)) else { return }
        try? data.write(to: root.appending(path: "index.json"), options: .atomic)
    }
}
