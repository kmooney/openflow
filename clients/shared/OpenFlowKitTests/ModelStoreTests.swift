import XCTest
@testable import OpenFlowKit

@MainActor
final class ModelStoreTests: XCTestCase {

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
