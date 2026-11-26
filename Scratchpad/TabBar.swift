import SwiftUI

/// The column of tabs down the left edge: one chip per pad, and a button for a new one.
struct TabBar: View {
    let workspace: Workspace

    @State private var renaming: Workspace.Tab?
    @State private var newTitle = ""
    @State private var closing: Workspace.Tab?

    var body: some View {
        VStack(spacing: 2) {
            // Hug the tabs while they fit; scroll once there are too many.
            ViewThatFits(in: .vertical) {
                chips.fixedSize()
                ScrollView(.vertical, showsIndicators: false) { chips }
            }

            Button {
                workspace.addTab()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 44, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New page")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
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

    private var chips: some View {
        // Leading-aligned, so the titles line up down the column.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(workspace.tabs) { tab in
                chip(for: tab)
            }
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
                .frame(minWidth: 44, maxWidth: 170, minHeight: 36, alignment: .leading)
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
            glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.separator.opacity(0.6)))
        }
    }
}
