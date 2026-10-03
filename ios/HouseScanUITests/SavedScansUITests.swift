import XCTest

/// Saved scans from the onboarding, on synthetic scan folders the test writes and the app lists
/// through `-savedScansRoot` (Debug builds only). A completed scan is listed with its saved time
/// and a Practice tag only where its stamp says practice; an unfinished folder is not listed.
/// Share opens the system share sheet; a scan deleted since the list was made gets an error and
/// drops out; the list survives a relaunch; and a new scan still starts.
final class SavedScansUITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-saved-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testASavedScanSharesAfterARelaunchAndAMissingOneSaysSo() throws {
        try scan("practice", minutesAgo: 5, stamp: #"{"practice": true}"#)
        // A corrupt stamp says nothing: the scan is listed, untagged.
        try scan("real", minutesAgo: 30, stamp: "{not json")
        try scan("unfinished", minutesAgo: nil)

        let app = launch()
        openSavedScans(app)
        let practice = row(app, "practice")
        let real = row(app, "real")
        XCTAssertTrue(practice.waitForExistence(timeout: 10), "the practice scan is not listed")
        XCTAssertTrue(real.exists, "the real scan is not listed")
        XCTAssertFalse(row(app, "unfinished").exists, "a scan without a bundle is listed")
        XCTAssertTrue(practice.descendants(matching: .any)["savedScan.practice"].exists, "the practice scan has no Practice tag")
        XCTAssertFalse(real.descendants(matching: .any)["savedScan.practice"].exists, "a scan without a readable stamp is tagged Practice")
        // A practice scan walked a real wall; only its meter was a sample.
        // The row's text is one combined element, so match within labels.
        func says(_ element: XCUIElement, _ text: String) -> Bool {
            element.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch.exists
        }
        XCTAssertTrue(says(practice, "Practice scan with a sample meter"), "the practice scan doesn't say its meter was a sample")
        XCTAssertFalse(says(app, "real wall"), "a row says a scan wasn't of a real wall")
        attach(app, "savedScans-list")
        // The audit's text-size check changes the onboarding's top bar layout; the sheet must
        // stay open through it (it closed when the button owned it).
        try audit(app)

        // Share opens the system sheet, and closing it returns to the list.
        tapWhenReady(real.buttons["action.shareSavedScan"])
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "the share sheet never appeared")
        attach(app, "savedScans-shareSheet")
        if app.buttons["Close"].waitForExistence(timeout: 3) {
            app.buttons["Close"].tap()
        } else {
            sheet.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the share sheet did not close")

        // The practice scan's folder goes after the list was made, as a cleanup would take it.
        try FileManager.default.removeItem(at: root.appending(path: "practice"))
        tapWhenReady(practice.buttons["action.shareSavedScan"])
        let alert = app.alerts["This scan is no longer on this phone"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "a missing scan gave no error")
        attach(app, "savedScans-missing")
        alert.buttons["OK"].tap()
        XCTAssertTrue(practice.waitForNonExistence(timeout: 10), "the missing scan stayed in the list")
        XCTAssertTrue(real.exists)

        // A relaunch lists the completed scan again.
        app.terminate()
        app.launch()
        openSavedScans(app)
        XCTAssertTrue(row(app, "real").waitForExistence(timeout: 10), "the saved scan is gone after a relaunch")
        tapWhenReady(app.buttons["action.closeSavedScans"])

        // A new scan starts as before.
        if app.buttons["action.onboardingSkip"].waitForExistence(timeout: 5) { tapWhenReady(app.buttons["action.onboardingSkip"]) }
        tapWhenReady(app.buttons["action.finishOnboarding"])
        XCTAssertTrue(app.descendants(matching: .any)["screen.findMeter"].waitForExistence(timeout: 15), "a new scan did not start")
    }

    @MainActor
    func testNoSavedScansSaysWhereTheyComeFrom() throws {
        try scan("unfinished", minutesAgo: nil)
        let app = launch()
        openSavedScans(app)
        let empty = app.descendants(matching: .any)["savedScans.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "no empty state")
        XCTAssertFalse(app.buttons["action.shareSavedScan"].exists)
        attach(app, "savedScans-empty")
        try audit(app)
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-savedScansRoot", root.path, "-replay", FullFlowUITests.fixture, "-sampleResult", "-practiceMeter", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.onboarding"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func openSavedScans(_ app: XCUIApplication) {
        tapWhenReady(app.buttons["action.savedScans"])
        XCTAssertTrue(app.descendants(matching: .any)["savedScans"].waitForExistence(timeout: 10), "Saved scans did not open")
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["savedScan.\(id)"]
    }

    /// Waits for the element to take a tap before tapping it, so a sheet still sliding in
    /// doesn't swallow the tap.
    @MainActor
    private func tapWhenReady(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) never appeared", file: file, line: line)
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: 10)
        element.tap()
    }

    /// The shared audit (`AccessibilityAudit`): an issue fails only when it shows in two passes.
    @MainActor
    private func audit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let outcome = try AccessibilityAudit.run(app) { _ in Thread.sleep(forTimeInterval: 1) }
        for unread in outcome.unread { add(XCTAttachment(string: unread)) }
        XCTAssertTrue(outcome.persistent.isEmpty, outcome.persistent.map(\.finding.message).joined(separator: "\n"), file: file, line: line)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A scan folder with a keyframe and, unless `minutesAgo` is nil, a bundle saved that long
    /// ago: a synthetic packet whose first entry is manifest.json, as the app writes it.
    private func scan(_ name: String, minutesAgo: Double?, stamp: String? = nil) throws {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appending(path: "k00001.jpg"))
        if let stamp { try Data(stamp.utf8).write(to: folder.appending(path: "scan-stamp.json")) }
        guard let minutesAgo else { return }
        let bundle = folder.appending(path: "scan.zip")
        try StoredZip.archive([
            ("manifest.json", Data(#"{"version":"1.1"}"#.utf8)),
            ("photos/p00001.jpg", Data(repeating: 0xAB, count: 2048)),
        ]).write(to: bundle)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: bundle.path)
    }
}

/// A stored (uncompressed) zip, enough for a synthetic packet. The UI tests don't link
/// HouseScanKit, whose `ZipWriter` the app uses.
private enum StoredZip {
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            out.append(le: UInt32(0x0403_4B50)); out.append(le: UInt16(20)); out.append(le: UInt16(0)); out.append(le: UInt16(0))
            out.append(le: UInt16(0)); out.append(le: UInt16(0x21))
            out.append(le: crc); out.append(le: UInt32(entry.data.count)); out.append(le: UInt32(entry.data.count))
            out.append(le: UInt16(name.count)); out.append(le: UInt16(0))
            out.append(name); out.append(entry.data)

            central.append(le: UInt32(0x0201_4B50)); central.append(le: UInt16(20)); central.append(le: UInt16(20))
            central.append(le: UInt16(0)); central.append(le: UInt16(0)); central.append(le: UInt16(0)); central.append(le: UInt16(0x21))
            central.append(le: crc); central.append(le: UInt32(entry.data.count)); central.append(le: UInt32(entry.data.count))
            central.append(le: UInt16(name.count)); central.append(le: UInt16(0)); central.append(le: UInt16(0))
            central.append(le: UInt16(0)); central.append(le: UInt16(0)); central.append(le: UInt32(0)); central.append(le: offset)
            central.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        out.append(le: UInt32(0x0605_4B50)); out.append(le: UInt16(0)); out.append(le: UInt16(0))
        out.append(le: UInt16(entries.count)); out.append(le: UInt16(entries.count))
        out.append(le: UInt32(central.count)); out.append(le: directoryOffset); out.append(le: UInt16(0))
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
