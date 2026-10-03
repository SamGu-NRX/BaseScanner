import XCTest

/// "I can't check this area" through the real engine, on the synthetic wall with the bundled
/// sample answer (`-autopilotCannotCheck`). The answer must take back the scan's claims over the
/// spot's area, send the scan again and end on the result, which says the area went unchecked
/// rather than that something stands there. The sample names the same spot every time, so the
/// second answer is settled by the first; and after a ground refine takes the answer down
/// (`-injectGroundRise`, as GroundFreshnessUITests), the answer that comes back is settled the
/// same way, with the same notice and no second question. When the answer after it names no
/// spot, the result still says an area along the wall went unchecked; after "Something's there"
/// it doesn't.
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

    /// "I can't check this area", then an answer that names no spot (`-sampleResultAfterSpotAnswer`
    /// with Fixtures/results/reject-nearest.json). There is no spot to tie the answer to, but the
    /// area stays out of the scan, so the result says an area along the wall went unchecked, and
    /// neither speaks of "this spot" nor of something standing there.
    @MainActor
    func testCannotCheckThenNoSpotStillSaysAnAreaWasNotChecked() throws {
        try runToResult(answer: "-autopilotCannotCheck", thenAnswerFile: "reject-nearest") { app in
            let any = app.descendants(matching: .any)
            let notice = any["result.scanNotChecked"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "a result without a spot lost the area the homeowner couldn't check")
            XCTAssertEqual(ElementRead.snapshot(notice)?.label, "You couldn't check an area along this wall, so your scan leaves it out as not checked. Someone would need to check it in person.")
            XCTAssertFalse(any["result.spotNotChecked"].exists, "a result without a spot speaks of this spot")
            XCTAssertFalse(any["result.spotRefused"].exists, "the result says something stands there")
            self.attach(app, name: "engine-result-noSpot-scanNotChecked")
        }
    }

    /// "I can't check this area", then an answer that names another spot (Fixtures/results/
    /// spot-left.json), which the autopilot answers "It's clear". The result's own spot is clear,
    /// so it has no spot notice, but the first area is still out of the scan, and the result says
    /// so.
    @MainActor
    func testCannotCheckThenAnotherSpotStillSaysAnAreaWasNotChecked() throws {
        try runToResult(answer: "-autopilotCannotCheck", thenAnswerFile: "spot-left") { app in
            let any = app.descendants(matching: .any)
            let notice = any["result.scanNotChecked"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "a result for another spot lost the area the homeowner couldn't check")
            XCTAssertEqual(ElementRead.snapshot(notice)?.label, "You couldn't check an area along this wall, so your scan leaves it out as not checked. Someone would need to check it in person.")
            XCTAssertFalse(any["result.spotNotChecked"].exists, "the other spot, answered clear, reads as not checked")
            XCTAssertFalse(any["result.spotRefused"].exists, "the result says something stands there")
            self.attach(app, name: "engine-result-otherSpot-scanNotChecked")
        }
    }

    /// The same answer without a spot after "Something's there": nothing was left unchecked, so
    /// the result says nothing about an unchecked area.
    @MainActor
    func testSomethingThereThenNoSpotLeavesNothingUnchecked() throws {
        try runToResult(answer: "-autopilotSomethingThere", thenAnswerFile: "reject-nearest") { app in
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["result.headline"].waitForExistence(timeout: 10))
            for id in ["result.scanNotChecked", "result.spotNotChecked", "result.spotRefused"] {
                XCTAssertFalse(any[id].exists, "\(id) on a result without a spot after Something's there")
            }
        }
    }

    /// Runs the synthetic wall to the result with `answer` as the first spot answer and every
    /// upload after it answered with Fixtures/results/`thenAnswerFile`.json
    /// (`-sampleResultAfterSpotAnswer`), then hands the held result to `check`. Later spot checks
    /// are answered "It's clear".
    @MainActor
    private func runToResult(answer: String, thenAnswerFile: String, check: (XCUIApplication) -> Void) throws {
        let files = FileManager.default
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: gate) }
        // Every screen but the result is let through; the result is held for the test.
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading", "spotConfirm"] {
            try Data().write(to: gate.appending(path: phase))
        }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/results/\(thenAnswerFile).json").path
        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-sampleResult", answer, "-sampleResultAfterSpotAnswer", file,
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(waitUntil(timeout: 300) { files.fileExists(atPath: gate.appending(path: "result.held").path) }, "the autopilot never reached the result")
        XCTAssertTrue(files.fileExists(atPath: gate.appending(path: "spot-refusal.json").path), "the spot check was never answered \(answer)")
        XCTAssertTrue(app.descendants(matching: .any)["screen.result"].exists)
        check(app)
    }

    /// The result's notice says the area went unchecked, never that something stands there. The
    /// spot's own notice replaces the scan-wide one.
    @MainActor
    private func assertNotCheckedNotice(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        let notice = any["result.spotNotChecked"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the result doesn't say the area wasn't checked")
        XCTAssertEqual(ElementRead.snapshot(notice)?.label, "You couldn't check the area around this spot, so your scan leaves it out as not checked. Someone would need to check it in person.")
        XCTAssertFalse(any["result.spotRefused"].exists, "the result says something stands where the homeowner said they couldn't check")
        XCTAssertFalse(any["result.scanNotChecked"].exists, "the result repeats the spot's notice for the whole wall")
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
