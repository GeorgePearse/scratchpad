import SwiftUI

/// The strip of tabs: one chip per pad, and a button for a new one.
struct TabBar: View {
    let workspace: Workspace

    @State private var renaming: Workspace.Tab?
    @State private var newTitle = ""
    @State private var closing: Workspace.Tab?

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        chip(for: tab)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                workspace.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .tabBarBackground()
        .alert("Rename tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") {
                if let renaming { workspace.rename(renaming.id, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Close \u{201C}\(closing?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close and delete", role: .destructive) {
                if let closing { workspace.close(closing.id) }
            }
        } message: {
            Text("Everything on this pad is deleted. This can't be undone.")
        }
    }

    private func chip(for tab: Workspace.Tab) -> some View {
        let isSelected = tab.id == workspace.selectedID
        return Button {
            workspace.select(tab.id)
        } label: {
            Text(tab.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, maxWidth: 180, minHeight: 36)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newTitle = tab.title
                renaming = tab
            }
            Button("Close", systemImage: "xmark", role: .destructive) {
                requestClose(tab)
            }
        }
        .accessibilityLabel("Tab, \(tab.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Close") { requestClose(tab) }
    }

    /// An empty pad closes at once; one with work on it asks first.
    private func requestClose(_ tab: Workspace.Tab) {
        if workspace.hasContent(tab.id) {
            closing = tab
        } else {
            workspace.close(tab.id)
        }
    }
}

private extension View {
    @ViewBuilder
    func tabBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        }
    }
}
