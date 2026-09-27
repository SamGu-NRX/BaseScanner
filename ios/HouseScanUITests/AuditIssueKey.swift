import XCTest

/// Which accessibility audit issue counts as the same one in two audit passes. Both audit loops
/// (FullFlowUITests and ScreenStatesUITests) fail only on issues found in both passes, so the key
/// decides whether a persistent failure is kept or discarded.
///
/// An element with an identifier is keyed by it alone, not by its label: live labels change
/// between passes ("12 photos taken" becomes "13 photos taken" on the photo count), and a label
/// in the key made one failure on one element look like two different issues, so it was dropped.
/// Elements that share an identifier (every feature row's delete button) share a key; an issue on
/// one row in the first pass and another row in the second then counts as repeated, which can
/// only fail the test, never hide a failure.
///
/// An element without an identifier has nothing stable but its label, so that is the fallback.
/// Its frame is not: ScreenStatesUITests scrolls between the passes. An unidentified element whose
/// label changes between passes can still escape the repeat check, so anything on screen whose
/// text changes live should carry an identifier. An issue with no element is keyed by its type.
enum AuditIssueKey {
    static func key(auditType: UInt64, identifier: String?, label: String?) -> String {
        if let identifier, !identifier.isEmpty { return "\(auditType)|id:\(identifier)" }
        if let label, !label.isEmpty { return "\(auditType)|label:\(label)" }
        return "\(auditType)|no element"
    }

    /// The keys found in both passes, sorted.
    static func repeated<First, Second>(_ first: [String: First], _ second: [String: Second]) -> [String] {
        first.keys.filter { second[$0] != nil }.sorted()
    }
}

/// Runs in the UI test bundle without launching the app.
final class AuditIssueKeyTests: XCTestCase {
    private let contrast = XCUIAccessibilityAuditType.contrast.rawValue

    func testALabelChangeCannotClearARepeatedIssue() {
        let first = [AuditIssueKey.key(auditType: contrast, identifier: "photoCount", label: "12 photos taken"): "pass 1"]
        let second = [AuditIssueKey.key(auditType: contrast, identifier: "photoCount", label: "13 photos taken"): "pass 2"]
        XCTAssertEqual(AuditIssueKey.repeated(first, second).count, 1, "the same element failing twice must count as repeated")
    }

    func testDifferentChecksOnOneElementStayApart() {
        let contrastKey = AuditIssueKey.key(auditType: contrast, identifier: "photoCount", label: "12 photos taken")
        let clipped = AuditIssueKey.key(
            auditType: XCUIAccessibilityAuditType.textClipped.rawValue, identifier: "photoCount", label: "12 photos taken")
        XCTAssertNotEqual(contrastKey, clipped)
    }

    func testElementsWithoutAnIdentifierFallBackToTheirLabel() {
        XCTAssertEqual(
            AuditIssueKey.key(auditType: contrast, identifier: "", label: "Done"),
            AuditIssueKey.key(auditType: contrast, identifier: nil, label: "Done"))
        XCTAssertNotEqual(
            AuditIssueKey.key(auditType: contrast, identifier: "", label: "Done"),
            AuditIssueKey.key(auditType: contrast, identifier: "", label: "Next"))
        // An identifier never collides with a label that happens to read the same.
        XCTAssertNotEqual(
            AuditIssueKey.key(auditType: contrast, identifier: "Done", label: nil),
            AuditIssueKey.key(auditType: contrast, identifier: nil, label: "Done"))
        XCTAssertEqual(AuditIssueKey.key(auditType: contrast, identifier: nil, label: nil), "\(contrast)|no element")
    }

    func testAnIssueFoundOnlyOnceIsNotRepeated() {
        let first = [AuditIssueKey.key(auditType: contrast, identifier: "instruction", label: "Slow down"): 1]
        let second = [AuditIssueKey.key(auditType: contrast, identifier: "photoCount", label: "3 photos taken"): 1]
        XCTAssertTrue(AuditIssueKey.repeated(first, second).isEmpty)
    }
}
