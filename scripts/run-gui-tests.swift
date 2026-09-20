// ABOUTME: Runs XCUITest while the host retains native menu automation permissions.
// ABOUTME: Handles the one menu activation that XCTest cannot reliably dispatch on this host.

import AppKit
import Foundation

struct MenuRequest: Decodable {
    let processID: Int32
    let responsePath: String
}

struct MenuResponse: Codable {
    let succeeded: Bool
    let detail: String
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(
        try String(contentsOf: root.appendingPathComponent("docs/gui-test-harness-help.md"), encoding: .utf8))
    exit(0)
}
if arguments.contains("--version") {
    print("superscale-gui-tests 1.0")
    exit(0)
}

func activatePaste(_ request: MenuRequest) {
    let responseURL = URL(fileURLWithPath: request.responsePath).resolvingSymlinksInPath()
    let temporaryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Containers/com.tadgpaul.superscale.uitests.xctrunner/Data/tmp"
    ).resolvingSymlinksInPath()
    let directory = responseURL.deletingLastPathComponent()
    // The test creates this per-request directory and pending file before emitting the request.
    guard request.processID > 0, responseURL.lastPathComponent == "response.json",
        directory.deletingLastPathComponent() == temporaryRoot,
        directory.lastPathComponent.hasPrefix("superscale-menu-"),
        NSRunningApplication(processIdentifier: request.processID)?.bundleIdentifier
            == "com.tadgpaul.superscale",
        (try? Data(contentsOf: responseURL).isEmpty) == true,
        FileManager.default.fileExists(atPath: responseURL.path)
    else { return }
    let press = Process()
    press.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    press.arguments = [
        "-e",
        "tell application \"System Events\" to tell (first process whose unix id is \(request.processID)) "
            + "to click menu item \"Paste Image\" of menu \"Edit\" of menu bar item \"Edit\" of menu bar 1",
    ]
    let errors = Pipe()
    press.standardError = errors
    press.standardOutput = Pipe()
    let response: MenuResponse
    do {
        try press.run()
        let deadline = Date().addingTimeInterval(8)
        while press.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if press.isRunning { press.terminate() }
        press.waitUntilExit()
        response = MenuResponse(
            succeeded: press.terminationStatus == 0,
            detail: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    } catch {
        response = MenuResponse(succeeded: false, detail: error.localizedDescription)
    }
    do {
        try JSONEncoder().encode(response).write(to: responseURL, options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("Native menu response failed: \(error)\n".utf8))
    }
}

let runner = Process()
runner.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
runner.currentDirectoryURL = root
runner.arguments =
    [
        "test", "-project", "SuperscaleApp/SuperscaleApp.xcodeproj", "-scheme", "SuperscaleWithTests",
        "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
    ] + arguments
let output = Pipe()
runner.standardOutput = output
runner.standardError = output
try runner.run()
var pending = Data()
let prefix = "SUPERSCALE_NATIVE_PASTE "
while true {
    let data = output.fileHandleForReading.availableData
    if data.isEmpty { break }
    FileHandle.standardOutput.write(data)
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[..<newline], as: UTF8.self)
        pending.removeSubrange(...newline)
        guard line.hasPrefix(prefix),
            let request = try? JSONDecoder().decode(
                MenuRequest.self, from: Data(line.dropFirst(prefix.count).utf8))
        else { continue }
        activatePaste(request)
    }
}
runner.waitUntilExit()
exit(runner.terminationStatus)
