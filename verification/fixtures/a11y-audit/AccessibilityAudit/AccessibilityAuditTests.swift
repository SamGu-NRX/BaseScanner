import XCTest

/// Launches the app under test by bundle id with the launch arguments it is given, then runs
/// `performAccessibilityAudit` once per distinct screen until the app stops changing.
///
/// A screen is identified by the labels of its static texts and buttons, so a new instruction
/// counts as a new screen. Each issue is printed as one `A11Y_ISSUE=<json>` line and each
/// screen as `A11Y_SCREEN=<json>`, which hsverify.a11yaudit reads from the test output.
/// Screenshots go to AUDIT_OUT on the host.
///
/// Inputs arrive as environment variables (set on the xcodebuild command line with the
/// TEST_RUNNER_ prefix): AUDIT_BUNDLE, AUDIT_ARGS (arguments separated by U+001F),
/// AUDIT_SECONDS (overall limit), AUDIT_IDLE (stop after this long without a new screen),
/// AUDIT_OUT (folder for screenshots).
final class AccessibilityAuditTests: XCTestCase {
    @MainActor
    func testAuditEveryScreen() throws {
        let env = ProcessInfo.processInfo.environment
        let bundle = try XCTUnwrap(env["AUDIT_BUNDLE"], "AUDIT_BUNDLE is required")
        let args = (env["AUDIT_ARGS"] ?? "").split(separator: "\u{1F}").map(String.init)
        let limit = Double(env["AUDIT_SECONDS"] ?? "") ?? 120
        let idle = Double(env["AUDIT_IDLE"] ?? "") ?? 15
        let out = env["AUDIT_OUT"].map { URL(fileURLWithPath: $0) }

        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = args
        app.launch()

        let start = Date()
        var lastChange = Date()
        var seen: [String] = []
        while Date().timeIntervalSince(start) < limit, Date().timeIntervalSince(lastChange) < idle {
            guard app.state == .runningForeground else {
                emit("A11Y_SCREEN", ["index": seen.count + 1, "error": "app not running"])
                break
            }
            guard let labels = screenLabels(app) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }
            let key = labels.joined(separator: "\n")
            if !seen.contains(key) {
                seen.append(key)
                lastChange = Date()
                audit(app, index: seen.count, labels: labels, out: out,
                      at: Date().timeIntervalSince(start))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// Labels from one snapshot of the accessibility tree. Querying elements and then reading
    /// each label is two round trips, and a button that disappears in between (the screen
    /// changing) fails the whole test.
    @MainActor
    private func screenLabels(_ app: XCUIApplication) -> [String]? {
        guard let root = try? app.snapshot() else { return nil }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ node: any XCUIElementSnapshot) {
            switch node.elementType {
            case .staticText: texts.append("text:" + node.label)
            case .button: buttons.append("button:" + node.label)
            default: break
            }
            node.children.forEach(walk)
        }
        walk(root)
        return texts + buttons
    }

    @MainActor
    private func audit(
        _ app: XCUIApplication, index: Int, labels: [String], out: URL?, at seconds: Double
    ) {
        var shot: String? = nil
        if let out {
            let name = String(format: "a11y-%02d.png", index)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: out.appendingPathComponent(name))
            shot = name
        }
        var issues = 0
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                issues += 1
                self.emit("A11Y_ISSUE", [
                    "screen": index,
                    "type": String(describing: issue.auditType),
                    "description": issue.compactDescription,
                    "detail": issue.detailedDescription,
                    "element": issue.element.map { "\($0.elementType.rawValue) \($0.label)" } ?? "",
                ])
                return true  // record every issue; never stop at the first
            }
        } catch {
            emit("A11Y_SCREEN", ["index": index, "error": "\(error)"])
        }
        emit("A11Y_SCREEN", [
            "index": index, "seconds": seconds, "labels": labels, "issues": issues,
            "screenshot": shot ?? "",
        ])
    }

    private func emit(_ tag: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        print("\(tag)=\(String(decoding: data, as: UTF8.self))")
    }
}
