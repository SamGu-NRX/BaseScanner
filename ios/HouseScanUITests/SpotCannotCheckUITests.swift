import XCTest

/// "I can't check this area" through the real engine, on the synthetic wall with the bundled
/// sample answer (`-autopilotCannotCheck`). The answer must take back the scan's claims over the
/// spot's area, send the scan again and end on the result, which says the area went unchecked
/// rather than that something stands there. The sample names the same spot every time, so the
/// second answer is settled by the first; and after a ground refine takes the answer down
/// (`-injectGroundRise`, as GroundFreshnessUITests), the answer that comes back is settled the
/// same way, with the same notice and no second question.
final class SpotCannotCheckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCannotCheckLeavesTheAreaUnseenAndTheResultSaysSo() throws {
        let files = FileManager.default
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: gate) }
        // The spot check and the result are held for the test; every other screen is let through.
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading"] {
            try Data().write(to: gate.appending(path: phase))
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-sampleResult", "-autopilotCannotCheck", "-injectGroundRise", "0.05",
        ]
        app.launch()
        let any = app.descendants(matching: .any)

        // 1. The engine's spot check offers all three answers.
        XCTAssertTrue(waitUntil(timeout: 300) { files.fileExists(atPath: gate.appending(path: "spotConfirm.held").path) }, "the autopilot never reached the spot check")
        XCTAssertTrue(any["screen.spotConfirm"].exists)
        for id in ["action.spotClear", "action.spotSomethingThere", "action.spotCannotCheck"] {
            XCTAssertTrue(app.buttons[id].exists, "the spot check has no \(id)")
        }
        XCTAssertEqual(app.buttons["action.spotCannotCheck"].label, "I can't check this area")
        attach(app, name: "engine-spotConfirm")
        try audit(app, "spotConfirm")
        try Data().write(to: gate.appending(path: "spotConfirm"))

        // 2. The scan goes again and the result says the area wasn't checked. The acknowledgment
        // in between is up for 1.5 s; SpotConfirmUITests reads it held still on the demo.
        let result = any["screen.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 120), "the scan sent again never reached the result")
        XCTAssertTrue(waitUntil(timeout: 30) { files.fileExists(atPath: gate.appending(path: "result.held").path) }, "the autopilot never finished with the result")
        assertNotCheckedNotice(app)
        attach(app, name: "engine-result-spotNotChecked")

        // 3. The scenes the last upload sent and the app exports claim nothing over the stretch
        // the answer withdrew, and still report wall and ground elsewhere.
        let refusal = try Data(contentsOf: gate.appending(path: "spot-refusal.json"))
        let withdrawn = try XCTUnwrap((JSONSerialization.jsonObject(with: refusal) as? [String: Any])?["withdrawn_span_ft"] as? [Double])
        XCTAssertEqual(withdrawn.count, 2)
        let low = try XCTUnwrap(withdrawn.first), high = try XCTUnwrap(withdrawn.last)
        XCTAssertGreaterThan(high - low, 1, "withdrawn: \(withdrawn)")
        for name in ["scene.json", "uploaded-scene.json"] {
            let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: gate.appending(path: name))) as? [String: Any])
            let coverage = try XCTUnwrap(scene["coverage"] as? [String: Any])
            let observed = try XCTUnwrap(coverage["observed"] as? [[String: Any]])
            for band in ["wall", "ground", "facing"] {
                let spans = observed.filter { $0["band"] as? String == band }.compactMap { $0["span_ft"] as? [Double] }
                for span in spans {
                    XCTAssertTrue(span[1] <= low + 1e-3 || span[0] >= high - 1e-3, "\(name): \(band) \(span) reaches into the withdrawn \(low)...\(high)")
                }
                if band != "facing" {
                    XCTAssertFalse(spans.isEmpty, "\(name): no \(band) observed at all")
                }
            }
        }

        // 4. A ground refine takes the answer down and sends the scan again. The answer that comes
        // back names the same spot: the earlier answer settles it, so the result returns with the
        // same notice and the homeowner is not asked again.
        let uploadGate = gate.appending(path: "uploading")
        let uploadHeld = gate.appending(path: "uploading.held")
        try files.removeItem(at: uploadGate)
        try? files.removeItem(at: uploadHeld)
        let trigger = gate.appending(path: "inject-ground")
        try Data().write(to: trigger)
        XCTAssertTrue(waitUntil(timeout: 10) { !files.fileExists(atPath: trigger.path) }, "the app never took the injected ground")
        XCTAssertTrue(any["screen.uploading"].waitForExistence(timeout: 10), "a ground refine left the old answer on the result")
        XCTAssertTrue(waitUntil(timeout: 60) { files.fileExists(atPath: uploadHeld.path) }, "the scan was not sent again")
        try Data().write(to: uploadGate)
        var askedAgain = false
        XCTAssertTrue(waitUntil(timeout: 60) {
            askedAgain = askedAgain || any["screen.spotConfirm"].exists
            return result.exists
        }, "the resend's answer never reached the result")
        XCTAssertFalse(askedAgain, "the same area was asked about again after the answer was taken down")
        assertNotCheckedNotice(app)
        attach(app, name: "engine-result-spotNotChecked-afterRefine")
    }

    /// The result's notice says the area went unchecked, never that something stands there.
    @MainActor
    private func assertNotCheckedNotice(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        let notice = any["result.spotNotChecked"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the result doesn't say the area wasn't checked")
        XCTAssertEqual(ElementRead.snapshot(notice)?.label, "You couldn't check the area around this spot, so your scan leaves it out as not checked. Someone would need to check it in person.")
        XCTAssertFalse(any["result.spotRefused"].exists, "the result says something stands where the homeowner said they couldn't check")
    }

    /// As FullFlowUITests: an issue fails only when a second pass, after a system banner has had
    /// time to leave, finds it again.
    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        let outcome = try AccessibilityAudit.run(app) { _ in Thread.sleep(forTimeInterval: 6) }
        for (_, finding) in outcome.persistent {
            XCTFail("screen.\(screen): \(finding.message)")
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
    }
}
