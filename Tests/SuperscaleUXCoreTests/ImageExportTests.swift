// ABOUTME: Exercises W151 cache-only export planning, file output and destination selection.
// ABOUTME: Uses local files and explicit failure boundaries without processing or network services.

import Foundation
import XCTest

@testable import SuperscaleUXCore

final class ImageExportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func cached(_ id: String, width: Int, height: Int, recency: Int, text: String)
        -> CachedExportImage
    {
        CachedExportImage(
            assetID: id, width: width, height: height, sizing: "4x", recency: recency, data: Data(text.utf8))
    }

    func test_snapshotRetainsRankedBytesAndFallsBackOnlyWithoutCache_RT151_6() throws {
        let root = try temporaryDirectory()
        var locks = ["smaller", "area", "tie", "evicted", "inflight"].map {
            ExportLock(id: $0, sourceURL: root.appendingPathComponent("generated-\($0).png"))
        }
        for lock in locks { try Data("stored-\(lock.id)".utf8).write(to: lock.sourceURL) }
        var cache = [
            cached("smaller", width: 1, height: 1, recency: 0, text: "small-cache"),
            cached("area", width: 20, height: 10, recency: 1, text: "largest"),
            cached("area", width: 10, height: 10, recency: 9, text: "newer-smaller"),
            cached("tie", width: 20, height: 10, recency: 2, text: "old-tie"),
            cached("tie", width: 10, height: 20, recency: 3, text: "new-tie"),
        ]
        var reads: [URL] = []
        let plan = ImageExport.snapshot(locks: locks, renderings: cache) {
            reads.append($0)
            return try Data(contentsOf: $0)
        }
        // Mutate every producer-owned collection and the files after the snapshot.
        cache.removeAll()
        cache.append(cached("inflight", width: 100, height: 100, recency: 10, text: "late"))
        for lock in locks { try Data("replaced".utf8).write(to: lock.sourceURL) }
        locks.removeAll()
        XCTAssertEqual(plan.map(\.lock.id), ["smaller", "area", "tie", "evicted", "inflight"])
        XCTAssertEqual(
            try plan.map { String(decoding: try $0.source.get(), as: UTF8.self) },
            ["small-cache", "largest", "new-tie", "stored-evicted", "stored-inflight"])
        XCTAssertEqual(reads.map(\.lastPathComponent), ["generated-evicted.png", "generated-inflight.png"])
        XCTAssertEqual(plan.first?.filename, "generated-smaller_4x.png")
        XCTAssertEqual(plan.last?.filename, "generated-inflight.png")
    }

    func test_snapshotReadFailureDoesNotLoseOtherLocks_RT151_6() throws {
        let root = try temporaryDirectory()
        let locks = ["missing", "held"].map {
            ExportLock(id: $0, sourceURL: root.appendingPathComponent("\($0).jpg"))
        }
        let plan = ImageExport.snapshot(
            locks: locks, renderings: [cached("held", width: 2, height: 2, recency: 0, text: "held")])
        XCTAssertEqual(plan.count, 2)
        let failed = try XCTUnwrap(plan.first)
        XCTAssertThrowsError(try failed.source.get())
        XCTAssertEqual(try plan.last?.source.get(), Data("held".utf8))
    }

    func test_exportNeverOverwritesAndContinuesAfterWriteFailure_RT151_7() throws {
        let root = try temporaryDirectory()
        let existing = root.appendingPathComponent("generated-one_4x.png")
        try Data("existing".utf8).write(to: existing)
        let items = ["one_4x", "two", "three"].map {
            let lock = ExportLock(id: $0, sourceURL: root.appendingPathComponent("source-\($0).jpg"))
            return ExportItem(lock: lock, filename: "generated-\($0).png", source: .success(Data($0.utf8)))
        }
        var attempts: [String] = []
        let result = ImageExport.export(
            items, to: root, encodePNG: { Data("PNG:".utf8) + $0 },
            writeExclusive: { data, url in
                attempts.append(url.lastPathComponent)
                if url.lastPathComponent == "generated-two.png" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .withoutOverwriting)
            })
        XCTAssertEqual(result.successes.map(\.lock.id), ["one_4x", "three"])
        XCTAssertEqual(result.failures.map(\.lockID), ["two"])
        XCTAssertEqual(result.failures.first?.filename, "generated-two.png")
        XCTAssertTrue(attempts.contains("generated-three.png"), "A failed file must not abort later outputs")
        XCTAssertEqual(Array(attempts.prefix(2)), ["generated-one_4x.png", "generated-one_4x_1.png"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        let renamed = try XCTUnwrap(result.successes.first?.outputURL)
        XCTAssertEqual(renamed.lastPathComponent, "generated-one_4x_1.png")
        XCTAssertEqual(try Data(contentsOf: renamed), Data("PNG:one_4x".utf8))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("generated-three.png")), Data("PNG:three".utf8))
    }

    func test_encodingAndSnapshotFailuresAreReportedWithoutSubstitutingPixels_RT151_7() throws {
        let root = try temporaryDirectory()
        let missing = ExportLock(id: "missing", sourceURL: root.appendingPathComponent("missing.jpg"))
        let corrupt = ExportLock(id: "corrupt", sourceURL: root.appendingPathComponent("corrupt.jpg"))
        let items = [
            ExportItem(
                lock: missing, filename: "missing.png",
                source: .failure(
                    ExportFailure(lockID: "missing", filename: "missing.png", reason: "Unreadable"))),
            ExportItem(lock: corrupt, filename: "corrupt_4x.png", source: .success(Data())),
        ]
        var writes = 0
        let result = ImageExport.export(
            items, to: root, encodePNG: { _ in throw CocoaError(.fileReadCorruptFile) },
            writeExclusive: { _, _ in writes += 1 })
        XCTAssertTrue(result.successes.isEmpty)
        XCTAssertEqual(result.failures.map(\.lockID), ["missing", "corrupt"])
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(result.failures.allSatisfy { !$0.reason.contains(root.path) })
    }

    func test_destinationUsesWritableFirstRunAndStoredChoiceWithoutPanel_RT151_8() throws {
        let root = try temporaryDirectory()
        for intent in [OutputFolderIntent.defaultDownloads(root), .storedAvailable(root)] {
            var choices = 0
            var persisted: [URL] = []
            let chosen = try ImageExport.destination(
                for: intent, isWritable: { $0 == root }, isDirectory: { _ in true },
                choose: { _ in
                    choices += 1
                    return nil
                }, persist: { persisted.append($0) })
            XCTAssertEqual(chosen, root)
            XCTAssertEqual(choices, 0)
            XCTAssertTrue(persisted.isEmpty)
        }
    }

    func test_deniedDownloadsCanBeSelectedAndPersistedOnce_RT151_8() throws {
        let root = try temporaryDirectory()
        var granted = false
        var panels: [URL] = []
        var persisted: [URL] = []
        let chosen = try ImageExport.destination(
            for: .defaultDownloads(root), isWritable: { _ in granted }, isDirectory: { _ in true },
            choose: {
                panels.append($0)
                granted = true
                return root
            }, persist: { persisted.append($0) })
        XCTAssertEqual(chosen, root)
        XCTAssertEqual(panels, [root])
        XCTAssertEqual(persisted, [root])
    }

    func test_unavailableStoredFolderChoosesReplacementOrCancelsAtNearestParent_RT151_8() throws {
        let root = try temporaryDirectory()
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        let missing = root.appendingPathComponent("gone/child", isDirectory: true)
        var panels: [URL] = []
        var persisted: [URL] = []
        let replacement = try ImageExport.destination(
            for: .storedUnavailable(denied), isWritable: { $0 == root },
            isDirectory: { $0 == root || $0 == denied },
            choose: {
                panels.append($0)
                return root
            }, persist: { persisted.append($0) })
        XCTAssertEqual(replacement, root)
        XCTAssertEqual(panels, [denied])
        XCTAssertEqual(persisted, [root])
        panels.removeAll()
        persisted.removeAll()
        let cancelled = try ImageExport.destination(
            for: .storedUnavailable(missing), isWritable: { $0 == root }, isDirectory: { $0 == root },
            choose: {
                panels.append($0)
                return nil
            }, persist: { persisted.append($0) })
        XCTAssertNil(cancelled)
        XCTAssertEqual(panels, [root])
        XCTAssertTrue(persisted.isEmpty)
    }

    @MainActor
    func test_destinationResolutionControlsBatchExecution_RT151_8() async throws {
        let root = try temporaryDirectory()
        let unavailable = root.appendingPathComponent("gone/child", isDirectory: true)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        let invalid = root.appendingPathComponent("not-a-directory")
        let lock = ExportLock(id: "one", sourceURL: root.appendingPathComponent("source.jpg"))
        let items = [ExportItem(lock: lock, filename: "one.png", source: .success(Data("image".utf8)))]
        let cases: [(OutputFolderIntent, URL?, URL?, Bool)] = [
            (.defaultDownloads(root), nil, nil, true),
            (.defaultDownloads(root), root, root, true),
            (.storedUnavailable(denied), root, denied, true),
            (.storedUnavailable(unavailable), nil, root, false),
        ]
        for (intent, selection, panelStart, accepted) in cases {
            var panels: [URL] = []
            var persisted: [URL] = []
            var checkedDirectories: [URL] = []
            var checkedWritable: [URL] = []
            var granted = panelStart == nil
            var batches = 0
            var writes: [URL] = []
            let result = try await ImageExport.run(
                items,
                destination: {
                    try ImageExport.destination(
                        for: intent,
                        isWritable: {
                            checkedWritable.append($0)
                            return granted && $0 == root
                        },
                        isDirectory: {
                            checkedDirectories.append($0)
                            return $0 == root || $0 == denied
                        },
                        choose: {
                            panels.append($0)
                            granted = true
                            return selection
                        },
                        persist: { persisted.append($0) })
                },
                export: { plan, folder in
                    batches += 1
                    return ImageExport.export(
                        plan, to: folder, encodePNG: { $0 },
                        writeExclusive: { _, url in
                            writes.append(url)
                        })
                })
            XCTAssertEqual(panels, panelStart.map { [$0] } ?? [])
            XCTAssertEqual(persisted, selection.map { [$0] } ?? [])
            XCTAssertEqual(batches, accepted ? 1 : 0)
            XCTAssertEqual(writes, accepted ? [root.appendingPathComponent("one.png")] : [])
            XCTAssertEqual(result == nil, !accepted)
            if accepted {
                XCTAssertTrue(checkedDirectories.contains(root))
                XCTAssertTrue(checkedWritable.contains(root))
            }
        }
        for isDirectory in [false, true] {
            var persisted = false
            XCTAssertThrowsError(
                try ImageExport.destination(
                    for: .storedUnavailable(denied), isWritable: { _ in !isDirectory },
                    isDirectory: { $0 == root || ($0 == invalid && isDirectory) },
                    choose: { _ in invalid }, persist: { _ in persisted = true }))
            XCTAssertFalse(persisted, "An invalid or unwritable selection must not be persisted")
        }
    }

    func test_gateRefusesEveryReplacementAndReopensAfterCompletion_RT151_12() {
        var accepted: [WorkspaceAction] = []
        for action in WorkspaceAction.allCases {
            if ImageExport.allows(action, isSavingAll: true) { accepted.append(action) }
        }
        XCTAssertTrue(accepted.isEmpty, "Every overlapping save and replacement must be refused")
        for action in WorkspaceAction.allCases {
            XCTAssertTrue(ImageExport.allows(action, isSavingAll: false))
        }
    }

    @MainActor
    func test_missingSourcesReportWithoutDestinationOrWorker_RT151_6() async throws {
        let root = try temporaryDirectory()
        let lock = ExportLock(id: "missing", sourceURL: root.appendingPathComponent("missing.jpg"))
        let item = ExportItem(
            lock: lock, filename: "missing.png",
            source: .failure(
                ExportFailure(lockID: lock.id, filename: "missing.png", reason: "Unreadable")))
        var panels = 0
        var batches = 0
        let result = await ImageExport.run(
            [item],
            destination: {
                panels += 1
                return root
            },
            export: { _, _ in
                batches += 1
                return ExportResult()
            })
        XCTAssertEqual(result?.failures.map(\.lockID), ["missing"])
        XCTAssertEqual(panels, 0)
        XCTAssertEqual(batches, 0)
    }

    @MainActor
    func test_cacheSnapshotKeepsFourEntryBoundAndSurvivesEviction_RT151_6() throws {
        let store = RenderingStore()
        for index in 0..<4 {
            let key = RenderingKey(
                assetID: "lock-\(index)", modelID: "fixture", sizing: "4x", facesEnhanced: false)
            store.admit(
                RenderedImage(id: "\(index)"), for: key,
                exportImage: cached(
                    key.assetID, width: 20, height: 10, recency: index, text: "pixels-\(index)"))
        }
        let snapshot = store.exportSnapshot
        XCTAssertEqual(snapshot.count, 4)
        let newKey = RenderingKey(assetID: "new", modelID: "fixture", sizing: "4x", facesEnhanced: false)
        store.admit(
            RenderedImage(id: "new"), for: newKey,
            exportImage: cached("new", width: 20, height: 10, recency: 4, text: "new-pixels"))
        XCTAssertEqual(store.count, 4)
        XCTAssertEqual(store.exportSnapshot.count, 4)
        XCTAssertFalse(store.exportSnapshot.contains { $0.assetID == "lock-0" })
        store.forget()
        XCTAssertTrue(store.exportSnapshot.isEmpty)
        XCTAssertEqual(snapshot.map(\.data), (0..<4).map { Data("pixels-\($0)".utf8) })
    }

    func test_preferencesPreserveMissingSelectionWhileRetainingDownloadsFallback_RT151_8() throws {
        let suite = "superscale.w151.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        let missing = root.appendingPathComponent("missing")
        var available = true
        let store = GenerationPreferencesStore(defaults: defaults, folderValidator: { _ in available })
        XCTAssertEqual(store.outputFolderIntent(defaultDownloads: root), .defaultDownloads(root))
        try store.save(
            GenerationPreferences(
                outputFolder: missing, defaultModelID: "fixture", defaultUpscaleModelID: "auto",
                defaultPromptPackID: nil))
        XCTAssertEqual(store.outputFolderIntent(defaultDownloads: root), .storedAvailable(missing))
        available = false
        XCTAssertEqual(store.outputFolderIntent(defaultDownloads: root), .storedUnavailable(missing))
        XCTAssertEqual(
            store.load().outputFolder, GenerationPreferences.defaultOutputFolder,
            "AC95.4 effective fallback must remain intact")
    }
}
