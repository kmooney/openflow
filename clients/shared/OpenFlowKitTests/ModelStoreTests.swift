import XCTest
@testable import OpenFlowKit

@MainActor
final class ModelStoreTests: XCTestCase {

    @MainActor
    private func makeStore() throws -> (ModelStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "selectedModel")
        return (ModelStore(directory: dir, bundle: Bundle(for: ModelStoreTests.self)), dir)
    }

    private func fakeModel(_ id: String, in dir: URL) throws {
        let model = try XCTUnwrap(ModelCatalog.model(id: id))
        try Data(repeating: 0, count: 8)
            .write(to: dir.appendingPathComponent(model.filename))
    }

    func testCatalogIsCoherent() {
        XCTAssertFalse(ModelCatalog.all.isEmpty)
        XCTAssertNotNil(ModelCatalog.model(id: ModelCatalog.bundledID),
                        "the bundled default must exist in the catalogue")
        for m in ModelCatalog.all {
            XCTAssertGreaterThan(m.bytes, 0)
            XCTAssertFalse(m.note.isEmpty, "\(m.id) needs an honest description")
            XCTAssertTrue(m.downloadURL.absoluteString.hasSuffix(m.filename))
        }
    }

    func testInstalledReflectsWhatIsOnDisk() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(store.installed.contains("small.en"))
        try fakeModel("small.en", in: dir)
        store.refresh()
        XCTAssertTrue(store.installed.contains("small.en"))
        XCTAssertNotNil(store.location(of: "small.en"))
    }

    func testSelectionPersistsAndDrivesTheEngine() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeModel("small.en", in: dir)
        store.refresh()

        var reloaded: URL?
        store.onSelectionChanged = { reloaded = $0 }
        store.select("small.en")

        XCTAssertEqual(store.selectedID, "small.en")
        XCTAssertNotNil(reloaded, "selecting a model must tell the engine to reload")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedModel"), "small.en")
    }

    func testCannotSelectAModelThatIsNotThere() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = store.selectedID
        store.select("large-v3-turbo-q5_0")
        XCTAssertEqual(store.selectedID, before, "selection must not point at a missing file")
    }

    func testDeleteRemovesAndFallsBack() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeModel("small.en", in: dir)
        store.refresh()
        store.select("small.en")

        store.delete("small.en")
        XCTAssertFalse(store.installed.contains("small.en"))
        XCTAssertNotEqual(store.selectedID, "small.en",
                          "deleting the active model must not strand the selection")
        XCTAssertNil(store.activeURL, "nothing else installed, so nothing is active")

        // ...and with another model present it moves there rather than nowhere
        try fakeModel("tiny.en", in: dir)
        try fakeModel("small.en", in: dir)
        store.refresh()
        store.select("small.en")
        store.delete("small.en")
        XCTAssertEqual(store.selectedID, "tiny.en")
        XCTAssertNotNil(store.activeURL)
    }

    /// macOS ships no model at all, so the default is one that has to be
    /// downloaded and the store opens pointing at nothing until it is.
    func testAMissingDefaultLeavesNothingActiveRatherThanACorruptSelection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        UserDefaults.standard.removeObject(forKey: "selectedModel")

        let empty = ModelStore(directory: dir, bundle: Bundle(for: ModelStoreTests.self),
                               defaultID: "small.en")
        XCTAssertNil(empty.activeURL)
        XCTAssertTrue(empty.installed.isEmpty)

        try fakeModel("small.en", in: dir)
        let ready = ModelStore(directory: dir, bundle: Bundle(for: ModelStoreTests.self),
                               defaultID: "small.en")
        XCTAssertEqual(ready.selectedID, "small.en")
        XCTAssertNotNil(ready.activeURL)
    }

    /// `installed` is a Set, so falling back through it used to pick a
    /// different model between launches for anyone holding two.
    func testTheFallbackIsTheSameModelEveryLaunch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeModel("tiny.en", in: dir)
        try fakeModel("small.en", in: dir)

        for _ in 0..<8 {
            UserDefaults.standard.removeObject(forKey: "selectedModel")
            let store = ModelStore(directory: dir, bundle: Bundle(for: ModelStoreTests.self),
                                   defaultID: "large-v3-turbo-q5_0")
            XCTAssertEqual(store.selectedID, "tiny.en",
                           "first in catalogue order among what is installed")
        }
    }

    func testDiskUsageCountsDownloads() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.diskUsage(), 0)
        try fakeModel("small.en", in: dir)
        XCTAssertEqual(store.diskUsage(), 8)
    }
}

// MARK: - a second catalogue
//
// `ModelStore` served one catalogue for so long that several methods looked
// their ids up in `ModelCatalog` by name. That was invisible until a polish
// catalogue existed, and then it broke everything at once: nothing ever showed
// as installed, selection refused silently, and a finished download deselected
// itself.

final class SecondCatalogueTests: XCTestCase {

    private struct FakeModel: DownloadableModel {
        let id: String
        let filename: String
        let displayName: String
        let bytes: Int64
        let note: String
        let downloadURL: URL
    }

    private let catalog: [any DownloadableModel] = [
        FakeModel(id: "small-one", filename: "small-one.gguf", displayName: "Small One",
                  bytes: 100, note: "", downloadURL: URL(string: "https://example.invalid/a")!),
        FakeModel(id: "big-one", filename: "big-one.gguf", displayName: "Big One",
                  bytes: 200, note: "", downloadURL: URL(string: "https://example.invalid/b")!),
    ]

    @MainActor
    private func makeStore() throws -> (ModelStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(directory: dir, defaultID: "",
                               catalog: catalog,
                               defaultsKey: "test-\(UUID().uuidString)")
        return (store, dir)
    }

    /// The bug exactly: a file on disk must be recognised as installed even
    /// though its id appears in no Whisper catalogue.
    @MainActor
    func testFindsAModelFromItsOwnCatalogue() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("weights".utf8).write(to: dir.appendingPathComponent("small-one.gguf"))
        store.refresh()

        XCTAssertTrue(store.installed.contains("small-one"))
        XCTAssertNotNil(store.location(of: "small-one"))
    }

    /// Selection refused silently, which is what "tapping does nothing" was.
    @MainActor
    func testSelectingAnInstalledModelWorks() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("weights".utf8).write(to: dir.appendingPathComponent("big-one.gguf"))
        store.refresh()
        store.select("big-one")

        XCTAssertEqual(store.selectedID, "big-one")
        XCTAssertNotNil(store.activeURL)
    }

    /// A store over one catalogue must never fall back into another's model.
    @MainActor
    func testDeletingFallsBackWithinItsOwnCatalogue() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("weights".utf8).write(to: dir.appendingPathComponent("small-one.gguf"))
        try Data("weights".utf8).write(to: dir.appendingPathComponent("big-one.gguf"))
        store.refresh()
        store.select("big-one")
        store.delete("big-one")

        XCTAssertEqual(store.selectedID, "small-one",
                       "the fallback must stay inside this catalogue")
        XCTAssertFalse(store.installed.contains("big-one"))
    }

    /// Nothing installed means nothing selected — not a Whisper model.
    @MainActor
    func testDeletingTheLastModelSelectsNothing() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("weights".utf8).write(to: dir.appendingPathComponent("small-one.gguf"))
        store.refresh()
        store.select("small-one")
        store.delete("small-one")

        XCTAssertEqual(store.selectedID, "")
        XCTAssertNil(store.activeURL)
    }
}
