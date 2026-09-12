import Foundation
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
        // Whatever the user last chose, or nothing. "Nothing" is a supported
        // state, not a missing file: the deterministic rules still run.
        engine.polishModelPath = polish.activeURL?.path ?? ""
        NSLog("openflow: polish at launch — selected=%@ installed=%@ path=%@",
              polish.selectedID, polish.installed.sorted().joined(separator: ","),
              polish.activeURL?.path ?? "(none)")
        // `URL?`, not `URL`: choosing "None" is a selection like any other,
        // and a callback that could not express it meant the engine kept the
        // last model loaded — so a user who turned polish off still had their
        // text polished, and the history still recorded the model's name.
        polish.onSelectionChanged = { [weak engine] url in
            engine?.polishModelPath = url?.path ?? ""
        }
        engine.supportDirectory = support
        engine.warmUp()
        models.onSelectionChanged = { [weak engine] url in
            guard let url else { return }   // never for speech: a model is required
            engine?.useModel(at: url.path)
        }

        // The two word lists, as files, at the same paths macOS uses. iOS had
        // neither until now: `engine.vocabulary` was left empty on the one
        // platform whose bundled model is the small one, which is exactly the
        // platform that needs the help most.
        let vocabulary = WordListStore(url: support.appendingPathComponent("vocab.txt"),
                                       seed: vocabularySeed)
        let dictionary = WordListStore(url: support.appendingPathComponent("dictionary.txt"),
                                       seed: dictionarySeed)

        _state = StateObject(wrappedValue: AppState(
            engine: engine, store: store, models: models, polish: polish,
            vocabulary: vocabulary, dictionary: dictionary,
            handoff: Handoff(appGroup: OpenFlowIDs.appGroup)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .onChange(of: scenePhase) { _, phase in
                    // A half-second debounce is not a guarantee against being
                    // suspended; a word list the user typed and then swiped
                    // away from must already be on disk.
                    if phase != .active {
                        state.vocabulary.save()
                        state.dictionary.save()
                    }
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
