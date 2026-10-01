import Foundation
import Testing

/// The app's privacy manifest (`ios/HouseScan/PrivacyInfo.xcprivacy`) against the code that ships
/// in the app: the HouseScan target's Swift files and HouseScanKit's sources. A required-reason
/// API added without its category, or a category left declared after its last use is removed,
/// fails here. Only the categories are checked against the code; each reason is pinned by hand,
/// because whether a use fits a reason depends on what the code does with the value.
@Suite struct PrivacyManifestTests {
    private static let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../..")
        .standardizedFileURL

    /// Apple's required-reason APIs by category, as Swift spells them. Disk space and active
    /// keyboards are listed so a first use of them fails loudly too.
    private static let apis: [String: String] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": #"\bUserDefaults\b|@AppStorage|NSUbiquitousKeyValueStore"#,
        "NSPrivacyAccessedAPICategoryFileTimestamp": #"\.creationDate\b|\.modificationDate\b|fileModificationDate|contentModificationDateKey|creationDateKey|\bgetattrlist|\bfgetattrlist|\bfstatat\(|\bl?stat\(|\bfstat\("#,
        "NSPrivacyAccessedAPICategorySystemBootTime": #"\bsystemUptime\b|\bmach_absolute_time\b"#,
        "NSPrivacyAccessedAPICategoryDiskSpace": #"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize\b|\bstatv?fs\(|\bfstatv?fs\("#,
        "NSPrivacyAccessedAPICategoryActiveKeyboards": #"\bactiveInputModes\b"#,
    ]

    private static func manifest() throws -> [String: [String]] {
        let url = ios.appendingPathComponent("HouseScan/PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let root = try #require(plist as? [String: Any])
        let types = try #require(root["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for entry in types {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            #expect(declared[category] == nil, "\(category) is declared twice")
            declared[category] = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        return declared
    }

    /// Categories whose APIs appear in shipped Swift, with the first file that uses each.
    private static func usedCategories() throws -> [String: String] {
        var used: [String: String] = [:]
        for folder in ["HouseScan", "HouseScanKit/Sources"] {
            let root = ios.appendingPathComponent(folder)
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in walker where file.pathExtension == "swift" {
                // Comments name APIs without calling them.
                let code = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                    .joined(separator: "\n")
                for (category, pattern) in apis where used[category] == nil {
                    if code.range(of: pattern, options: .regularExpression) != nil {
                        used[category] = file.path.replacingOccurrences(of: ios.path + "/", with: "")
                    }
                }
            }
        }
        return used
    }

    @Test func everyUsedCategoryIsDeclaredAndNothingElse() throws {
        let declared = try Self.manifest()
        let used = try Self.usedCategories()
        for (category, file) in used.sorted(by: { $0.key < $1.key }) {
            #expect(declared[category] != nil, "\(file) uses \(category), which PrivacyInfo.xcprivacy does not declare")
        }
        for category in declared.keys.sorted() {
            #expect(used[category] != nil, "PrivacyInfo.xcprivacy declares \(category), which no shipped code uses")
        }
    }

    @Test func reasonsMatchTheUsesTracedInTheManifestComments() throws {
        #expect(try Self.manifest() == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1"],
        ])
    }
}
