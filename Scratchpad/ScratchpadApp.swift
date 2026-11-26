import SwiftUI

@main
struct ScratchpadApp: App {
    @State private var workspace = Workspace(scratch: ScratchpadApp.usesScratchStorage)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WorkspaceScreen(workspace: workspace)
                .task {
                    #if DEBUG
                    await DemoScript.runIfRequested(on: workspace.current)
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { workspace.saveAll() }
        }
    }

    /// The scripted demo and the UI tests run on throwaway storage, never on real pads.
    private static var usesScratchStorage: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demo") || UserDefaults.standard.bool(forKey: "cannedModel")
        #else
        false
        #endif
    }
}

/// The whole app: one pad at a time, with a strip of tabs to move between pads.
struct WorkspaceScreen: View {
    let workspace: Workspace

    var body: some View {
        // A new identity per tab gives each pad a fresh canvas view pointed at its own content.
        PadScreen(workspace: workspace, store: workspace.current)
            .id(workspace.selectedID)
    }
}

/// One pad: an endless page with two small clusters of controls.
struct PadScreen: View {
    let workspace: Workspace
    let store: PadStore
    @State private var showSettings = false

    var body: some View {
        ZStack {
            PadCanvas(
                store: store,
                diagram: store.diagram,
                document: store.document,
                summary: store.summary,
                tool: store.tool,
                fingerDraws: store.settings.fingerDraws
            )
            .ignoresSafeArea()

            if store.isBlank {
                hint
            }

            VStack {
                // Tabs on the left, tools on the right; they stack when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        TabBar(workspace: workspace).frame(maxWidth: 420, alignment: .leading)
                        Spacer(minLength: 0)
                        ControlBar(store: store, showSettings: $showSettings)
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        ControlBar(store: store, showSettings: $showSettings)
                        TabBar(workspace: workspace)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            // A new key or model should take effect on whatever is waiting.
            store.loop.retry()
        } content: {
            SettingsView(settings: store.settings, store: store)
        }
        .onAppear {
            #if DEBUG
            showSettings = UserDefaults.standard.bool(forKey: "showSettings")
            #endif
        }
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 44, weight: .light))
            Text("Draw a diagram")
                .font(.title2.weight(.semibold))
            Text(store.needsAPIKey
                ? "Add an API key in settings and your boxes, arrows and handwriting become clean shapes as you draw."
                : "Boxes, arrows and handwriting become clean shapes as you draw.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The hint must never swallow a pencil stroke.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
