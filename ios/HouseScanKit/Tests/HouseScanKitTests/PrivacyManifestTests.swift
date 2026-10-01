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

    /// Apple's required-reason APIs by category, as Swift can spell them. A C call may have
    /// spaces before its parenthesis. Disk space and active keyboards are listed so a first use
    /// of them fails loudly too.
    static let apis: [String: String] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": #"\bUserDefaults\b|@AppStorage\b|\bNSUbiquitousKeyValueStore\b"#,
        "NSPrivacyAccessedAPICategoryFileTimestamp": #"\bcreationDate\b|\bmodificationDate\b|\bfileModificationDate\b|\bcontentModificationDate(Key)?\b|\bcreationDateKey\b|\battributesOfItem\b|\bfileAttributes\b|\b(f|l)?getattrlist(bulk|at)?\s*\(|\b(f|l)?stat(at)?\s*\("#,
        "NSPrivacyAccessedAPICategorySystemBootTime": #"\bsystemUptime\b|\bmach_absolute_time\b"#,
        "NSPrivacyAccessedAPICategoryDiskSpace": #"\bvolumeAvailableCapacity\w*|\bvolumeTotalCapacity\w*|\bsystemFreeSize\b|\bsystemSize\b|\bf?statv?fs\s*\("#,
        "NSPrivacyAccessedAPICategoryActiveKeyboards": #"\bactiveInputModes\b"#,
    ]

    /// Swift source with its comments blanked. Comment markers inside string literals stay code,
    /// so a URL in a string can't hide the rest of its line. Block comments may nest, as in Swift.
    static func code(_ source: String) -> String {
        var out = ""
        var chars = Array(source)[...]
        var depth = 0
        var inString = false
        while let c = chars.first {
            let next = chars.dropFirst().first
            if depth > 0 {
                if c == "*", next == "/" { depth -= 1; chars = chars.dropFirst(2); continue }
                if c == "/", next == "*" { depth += 1; chars = chars.dropFirst(2); continue }
                if c == "\n" { out.append(c) }
                chars = chars.dropFirst()
            } else if inString {
                out.append(c)
                if c == "\\", let escaped = next { out.append(escaped); chars = chars.dropFirst(2); continue }
                if c == "\"" || c == "\n" { inString = false }
                chars = chars.dropFirst()
            } else if c == "/", next == "/" {
                chars = chars.drop { $0 != "\n" }
            } else if c == "/", next == "*" {
                depth = 1
                chars = chars.dropFirst(2)
            } else {
                if c == "\"" { inString = true }
                out.append(c)
                chars = chars.dropFirst()
            }
        }
        return out
    }

    /// The categories whose APIs appear in `source`'s code.
    static func categories(in source: String) -> Set<String> {
        let code = code(source)
        return Set(apis.compactMap { category, pattern in
            code.range(of: pattern, options: .regularExpression) == nil ? nil : category
        })
    }

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
                for category in categories(in: try String(contentsOf: file, encoding: .utf8)) where used[category] == nil {
                    used[category] = file.path.replacingOccurrences(of: ios.path + "/", with: "")
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

    // The scanner on its own, so a gap in it can't hide behind today's sources.

    @Test(arguments: [
        ("statfs (path, &stats)", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("let free = values.volumeAvailableCapacityForImportantUsage", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("fstatvfs(fd, &info)", "NSPrivacyAccessedAPICategoryDiskSpace"),
        ("let a = try fm.attributesOfItem(atPath: p)", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("let d = values.contentModificationDate", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("lstat (path, &s)", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("getattrlistbulk(fd, &list, buf, n, 0)", "NSPrivacyAccessedAPICategoryFileTimestamp"),
        ("let t = mach_absolute_time()", "NSPrivacyAccessedAPICategorySystemBootTime"),
        ("@AppStorage(\"k\") var on = false", "NSPrivacyAccessedAPICategoryUserDefaults"),
        ("let url = \"https://example.com\"; let up = ProcessInfo.processInfo.systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
        ("let s = \"/* not a comment\"; UserDefaults.standard.set(1, forKey: \"k\")", "NSPrivacyAccessedAPICategoryUserDefaults"),
        ("UITextInputMode.activeInputModes", "NSPrivacyAccessedAPICategoryActiveKeyboards"),
    ])
    func theScannerFindsAUse(source: String, category: String) {
        #expect(Self.categories(in: source) == [category])
    }

    @Test(arguments: [
        "// UserDefaults.standard is not used here",
        "/* systemUptime\n   /* nested */ mach_absolute_time */",
        "let status = statusText(code)",
        "let restated = 1",
    ])
    func theScannerIgnoresCommentsAndLookalikes(source: String) {
        #expect(Self.categories(in: source).isEmpty)
    }
}
