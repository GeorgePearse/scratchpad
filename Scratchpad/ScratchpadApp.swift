import SwiftUI

@main
struct ScratchpadApp: App {
    @State private var store = PadStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PadScreen(store: store)
                .task {
                    #if DEBUG
                    await DemoScript.runIfRequested(on: store)
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.saveNow() }
        }
    }
}

/// The whole app: a blank page with one small cluster of controls.
struct PadScreen: View {
    let store: PadStore
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PadCanvas(
                store: store,
                diagram: store.diagram,
                summary: store.summary,
                tool: store.tool,
                fingerDraws: store.settings.fingerDraws
            )
            .ignoresSafeArea()

            if store.isBlank {
                hint
            }

            ControlBar(store: store, showSettings: $showSettings)
                .padding(12)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            // A new key or model should take effect on whatever is waiting.
            store.loop.retry()
        } content: {
            SettingsView(settings: store.settings)
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
