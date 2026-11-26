import SwiftUI

/// The list of pages: a full-height strip down the left edge, with a button for a new page.
struct TabBar: View {
    let workspace: Workspace

    @State private var renaming: Workspace.Tab?
    @State private var newTitle = ""
    @State private var closing: Workspace.Tab?
    static let width: CGFloat = 148

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        row(for: tab)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            Button {
                workspace.addTab()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24, weight: .regular))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New page")
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .trailing) { Divider() }
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

    private func row(for tab: Workspace.Tab) -> some View {
        let isSelected = tab.id == workspace.selectedID
        return Button {
            workspace.select(tab.id)
        } label: {
            // The page in view is white on solid accent colour: tinted text on a tinted fill was
            // too faint to read.
            Text(tab.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(isSelected ? Color.accentColor : .clear)
                .contentShape(.rect)
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
