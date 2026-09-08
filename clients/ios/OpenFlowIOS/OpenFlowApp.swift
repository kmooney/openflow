import SwiftUI
import OpenFlowKit

@main
struct OpenFlowApp: App {
    @StateObject private var state: AppState

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let store = (try? Store(path: support.appendingPathComponent("history.sqlite").path))
            ?? Store.inMemory()
        let models = ModelStore(directory: support.appendingPathComponent("models"))
        // Falls back to the bundled model if the selection has gone missing.
        let modelPath = models.activeURL?.path
            ?? Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin")?.path
            ?? support.appendingPathComponent("models/ggml-base.en.bin").path

        let engine = DictationEngine(modelPath: modelPath, store: store)
        engine.supportDirectory = support
        engine.warmUp()
        models.onSelectionChanged = { [weak engine] url in engine?.useModel(at: url.path) }

        _state = StateObject(wrappedValue: AppState(
            engine: engine, store: store, models: models,
            handoff: Handoff(appGroup: OpenFlowIDs.appGroup)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .onOpenURL { url in
                    // Launched by the keyboard's mic key: start listening at
                    // once, so the user can speak without a second tap.
                    guard url.scheme == OpenFlowIDs.urlScheme, url.host == "dictate" else { return }
                    state.handedOffFromKeyboard = true
                    state.begin()
                }
        }
    }
}
