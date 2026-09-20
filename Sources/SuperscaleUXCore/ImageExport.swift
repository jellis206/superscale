// ABOUTME: Defines immutable image-export inputs, results, and local export boundaries.
// ABOUTME: Keeps cache selection and destination policy independent of AppKit.

import Foundation

public struct ExportLock: Sendable {
    public let id: String
    public let sourceURL: URL

    public init(id: String, sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
    }
}

public struct CachedExportImage: Sendable {
    public let assetID: String
    public let width: Int
    public let height: Int
    public let sizing: String
    public let recency: Int
    public let data: Data

    public init(assetID: String, width: Int, height: Int, sizing: String, recency: Int, data: Data) {
        self.assetID = assetID
        self.width = width
        self.height = height
        self.sizing = sizing
        self.recency = recency
        self.data = data
    }
}

public struct ExportFailure: Error, Equatable, Sendable {
    public let lockID: String
    public let filename: String
    public let reason: String

    public init(lockID: String, filename: String, reason: String) {
        self.lockID = lockID
        self.filename = filename
        self.reason = reason
    }
}

public struct ExportItem: Sendable {
    public let lock: ExportLock
    public let filename: String
    public let source: Result<Data, ExportFailure>

    public init(lock: ExportLock, filename: String, source: Result<Data, ExportFailure>) {
        self.lock = lock
        self.filename = filename
        self.source = source
    }
}

public struct ExportSuccess: Sendable {
    public let lock: ExportLock
    public let outputURL: URL
}

public struct ExportResult: Sendable {
    public var successes: [ExportSuccess] = []
    public var failures: [ExportFailure] = []

    public init() {}
}

public enum OutputFolderIntent: Equatable, Sendable {
    case defaultDownloads(URL)
    case storedAvailable(URL)
    case storedUnavailable(URL)
}

public enum WorkspaceAction: String, CaseIterable, Sendable {
    case saveAll, clear, openImage, openRecent, pasteImage, fileChooser, fileDrop
}

public enum ImageExport {
    /// Coordinates destination cancellation and one worker invocation; UI callers supply the panel boundary.
    @MainActor
    public static func run(
        _ items: [ExportItem], destination: () async throws -> URL?,
        export: ([ExportItem], URL) async -> ExportResult
    ) async rethrows -> ExportResult? {
        guard
            items.contains(where: {
                if case .success = $0.source { return true }
                return false
            })
        else {
            var result = ExportResult()
            result.failures = items.compactMap {
                if case .failure(let error) = $0.source { return error }
                return nil
            }
            return result
        }
        guard let directory = try await destination() else { return nil }
        return await export(items, directory)
    }

    /// All replacement routes share this gate; adding a route requires an explicit decision here.
    public static func allows(_ action: WorkspaceAction, isSavingAll: Bool) -> Bool {
        switch action {
        case .saveAll, .clear, .openImage, .openRecent, .pasteImage, .fileChooser, .fileDrop:
            return !isSavingAll
        }
    }

    public static func snapshot(
        locks: [ExportLock], renderings: [CachedExportImage],
        read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> [ExportItem] {
        locks.map { lock in
            let selected = renderings.filter { $0.assetID == lock.id }.max {
                let lhs = Double($0.width) * Double($0.height)
                let rhs = Double($1.width) * Double($1.height)
                return lhs == rhs ? $0.recency < $1.recency : lhs < rhs
            }
            let stem = lock.sourceURL.deletingPathExtension().lastPathComponent
            let suffix = selected.map { "_" + $0.sizing.replacingOccurrences(of: "/", with: "-") } ?? ""
            let filename = stem + suffix + ".png"
            do {
                let bytes = try selected?.data ?? read(lock.sourceURL)
                return ExportItem(lock: lock, filename: filename, source: .success(bytes))
            } catch {
                return ExportItem(
                    lock: lock, filename: filename,
                    source: .failure(
                        ExportFailure(
                            lockID: lock.id, filename: filename, reason: diagnostic("Read", error))))
            }
        }
    }

    public static func export(
        _ items: [ExportItem], to directory: URL,
        encodePNG: (Data) throws -> Data,
        writeExclusive: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) }
    ) -> ExportResult {
        var result = ExportResult()
        for item in items {
            var filename = item.filename
            do {
                let data = try encodePNG(item.source.get())
                var collision = 0
                while true {
                    let url = directory.appendingPathComponent(filename)
                    do {
                        try writeExclusive(data, url)
                        result.successes.append(ExportSuccess(lock: item.lock, outputURL: url))
                        break
                    } catch CocoaError.fileWriteFileExists {
                        collision += 1
                        let stem = (item.filename as NSString).deletingPathExtension
                        filename = "\(stem)_\(collision).png"
                    }
                }
            } catch let error as ExportFailure {
                result.failures.append(error)
            } catch {
                result.failures.append(
                    ExportFailure(
                        lockID: item.lock.id, filename: filename, reason: diagnostic("Export", error)))
            }
        }
        return result
    }

    /// Keep local paths and image data out of reports while retaining the failing operation and code.
    private static func diagnostic(_ operation: String, _ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoPermission, .fileWriteNoPermission:
                return "\(operation) failed: permission denied."
            case .fileReadNoSuchFile: return "\(operation) failed: source is missing."
            case .fileReadCorruptFile: return "\(operation) failed: image could not be decoded."
            case .fileWriteOutOfSpace: return "\(operation) failed: destination is full."
            default: break
            }
        }
        return "\(operation) failed (code \(error.code))."
    }

    public static func destination(
        for intent: OutputFolderIntent,
        isWritable: (URL) -> Bool,
        isDirectory: (URL) -> Bool,
        choose: (URL) -> URL?,
        persist: (URL) throws -> Void
    ) throws -> URL? {
        let requested: URL
        let mustChoose: Bool
        switch intent {
        case .defaultDownloads(let url), .storedAvailable(let url):
            requested = url
            mustChoose = false
        case .storedUnavailable(let url):
            requested = url
            mustChoose = true
        }
        if !mustChoose && isDirectory(requested) && isWritable(requested) { return requested }
        var startingDirectory = requested
        while !isDirectory(startingDirectory) {
            let path = startingDirectory.path
            let parentPath = (path as NSString).deletingLastPathComponent
            guard path != "/", !parentPath.isEmpty, parentPath != path else { break }
            startingDirectory = URL(fileURLWithPath: parentPath, isDirectory: false)
        }
        guard let selected = choose(startingDirectory) else { return nil }
        guard isDirectory(selected), isWritable(selected) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try persist(selected)
        return selected
    }
}
