// ABOUTME: Verifies v2 GUI release packaging and documented provider scope.
// ABOUTME: Uses local synthetic app bundles so no paid services or credentials are involved.

import Foundation
import XCTest

final class ReleasePackagingTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("superscale-release-packaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let fixtureRoot, FileManager.default.fileExists(atPath: fixtureRoot.path) {
            try FileManager.default.removeItem(at: fixtureRoot)
        }
        try super.tearDownWithError()
    }

    // RT-78.1
    func test_guiReleaseInspectorAcceptsCompletePromptPackBundle_RT78_1() throws {
        let app = try makeAppFixture(promptPackCount: 108)

        let result = try inspect(app)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("108 prompt packs"), result.output)
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeAppFixture(promptPackCount: Int) throws -> URL {
        let app = fixtureRoot.appendingPathComponent("Superscale.app")
        let resources = app
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("Superscale_SuperscaleUXCore.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<promptPackCount {
            let file = resources.appendingPathComponent(String(format: "image-fixture-%03d.md", index))
            try Data("Fixture prompt".utf8).write(to: file)
        }
        return app
    }

    private func inspect(_ app: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            projectRoot.appendingPathComponent("scripts/inspect-gui-release.sh").path,
            app.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

}
