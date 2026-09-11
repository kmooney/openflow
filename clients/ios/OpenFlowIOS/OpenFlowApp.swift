import SwiftUI
import OpenFlowKit

@main
struct OpenFlowApp: App {
    @StateObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let store = (try? Store(path: support.appendingPathComponent("history.sqlite").path))
            ?? Store.inMemory()
        let models = ModelStore(directory: support.appendingPathComponent("models"))
        // A second store over the same machinery: same downloads, same
        // selection, same deletion. Its own defaults key, or choosing a polish
        // model would silently change which speech model was selected.
        let polish = ModelStore(directory: support.appendingPathComponent("polish"),
                                defaultID: PolishCatalog.offID,
                                catalog: PolishCatalog.all,
                                defaultsKey: "selectedPolishModel")
        // Falls back to the bundled model if the selection has gone missing.
        let modelPath = models.activeURL?.path
            ?? Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin")?.path
            ?? support.appendingPathComponent("models/ggml-base.en.bin").path

        let engine = DictationEngine(modelPath: modelPath, store: store)
        engine.supportDirectory = support
        engine.warmUp()
        models.onSelectionChanged = { [weak engine] url in engine?.useModel(at: url.path) }

        _state = StateObject(wrappedValue: AppState(
            engine: engine, store: store, models: models, polish: polish,
            handoff: Handoff(appGroup: OpenFlowIDs.appGroup)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .onChange(of: scenePhase) { _, phase in
                    // Every arrival, not only a cold launch: coming back from
                    // the keyboard's "open the app" case looks identical to
                    // launching, and both mean the same thing — the user is
                    // here to talk.
                    guard phase == .active else { return }
                    state.openMicrophoneOnAppearing()
                }
                .onOpenURL { url in
                    // Arriving from the keyboard is not a different case: the
                    // scene became active, which already opened the microphone.
                    // All this adds is the note explaining where the text will
                    // go.
                    guard url.scheme == OpenFlowIDs.urlScheme, url.host == "dictate" else { return }
                    state.handedOffFromKeyboard = true
                }
        }
    }
}
