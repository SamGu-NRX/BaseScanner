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

    /// Swift source with its comments and string text blanked, so only code is searched: a
    /// string or a comment that names an API doesn't count as calling it. Interpolations
    /// (`\\(...)`, or `\\#(...)` in a raw string) are code and stay. Ordinary, multi-line
    /// (`"""`) and raw (`#"..."#`) strings each end only at their own delimiter, so a quote
    /// inside one can't hide the code after it. Block comments may nest, as in Swift.
    static func code(_ source: String) -> String {
        enum Mode {
            case code(parens: Int, interpolation: Bool)
            case string(hashes: Int, multiline: Bool)
        }
        let chars = Array(source)
        func at(_ i: Int) -> Character? { i < chars.count ? chars[i] : nil }
        func hashes(from i: Int) -> Int {
            var n = 0
            while at(i + n) == "#" { n += 1 }
            return n
        }
        /// Whether a string's closing delimiter starts at `i`: one quote, or three, then the
        /// string's hashes.
        func closes(at i: Int, hashes h: Int, multiline: Bool) -> Int? {
            let quotes = multiline ? 3 : 1
            guard (0..<quotes).allSatisfy({ at(i + $0) == "\"" }), hashes(from: i + quotes) >= h else { return nil }
            return quotes + h
        }
        var out = ""
        var modes: [Mode] = [.code(parens: 0, interpolation: false)]
        var commentDepth = 0
        var i = 0
        while let c = at(i) {
            let next = at(i + 1)
            if commentDepth > 0 {
                if c == "*", next == "/" { commentDepth -= 1; i += 2; continue }
                if c == "/", next == "*" { commentDepth += 1; i += 2; continue }
                if c == "\n" { out.append(c) }
                i += 1
                continue
            }
            switch modes[modes.count - 1] {
            case .string(let h, let multiline):
                if let length = closes(at: i, hashes: h, multiline: multiline) {
                    modes.removeLast()
                    out.append(contentsOf: chars[i..<(i + length)])
                    i += length
                } else if c == "\\", hashes(from: i + 1) >= h, at(i + 1 + h) == "(" {
                    modes.append(.code(parens: 1, interpolation: true))
                    out.append(contentsOf: chars[i...(i + 1 + h)])
                    i += 2 + h
                } else if c == "\\", h == 0, next != nil {
                    // An escape in an ordinary string: the escaped character is text.
                    out.append(next == "\n" ? "\n" : " ")
                    out.append(" ")
                    i += 2
                } else if c == "\n" {
                    // A single-line string can't span lines; end it here rather than hide code.
                    if !multiline { modes.removeLast() }
                    out.append(c)
                    i += 1
                } else {
                    out.append(" ")
                    i += 1
                }
            case .code(let parens, let interpolation):
                let h = c == "#" ? hashes(from: i) : 0
                if c == "/", next == "/" {
                    while let d = at(i), d != "\n" { i += 1 }
                } else if c == "/", next == "*" {
                    commentDepth = 1
                    i += 2
                } else if c == "\"" || (h > 0 && at(i + h) == "\"") {
                    let quote = i + h
                    let multiline = at(quote + 1) == "\"" && at(quote + 2) == "\""
                    let length = h + (multiline ? 3 : 1)
                    modes.append(.string(hashes: h, multiline: multiline))
                    out.append(contentsOf: chars[i..<(i + length)])
                    i += length
                } else {
                    if c == "(" {
                        modes[modes.count - 1] = .code(parens: parens + 1, interpolation: interpolation)
                    } else if c == ")", parens > 0 {
                        if interpolation, parens == 1 {
                            modes.removeLast()
                        } else {
                            modes[modes.count - 1] = .code(parens: parens - 1, interpolation: interpolation)
                        }
                    }
                    out.append(c)
                    i += 1
                }
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
        ("let on = \"\\(UserDefaults.standard.bool(forKey: \"k\"))\"", "NSPrivacyAccessedAPICategoryUserDefaults"),
        ("log(\"saved \\(n) at \\(f(\")\"))\"); let t = ProcessInfo.processInfo.systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
        // Raw strings: an interpolation is code, and a quote inside doesn't end the string.
        ("let s = #\"\\#(ProcessInfo.processInfo.systemUptime)\"#", "NSPrivacyAccessedAPICategorySystemBootTime"),
        ("let s = #\"a \" b\"#; let t = ProcessInfo.processInfo.systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
        // A multi-line string ends at its own delimiter, with code after it on that line.
        ("let s = \"\"\"\n  \"quoted\" text\n  \"\"\".count + Int(ProcessInfo.processInfo.systemUptime)", "NSPrivacyAccessedAPICategorySystemBootTime"),
    ])
    func theScannerFindsAUse(source: String, category: String) {
        #expect(Self.categories(in: source) == [category])
    }

    @Test(arguments: [
        "// UserDefaults.standard is not used here",
        "/* systemUptime\n   /* nested */ mach_absolute_time */",
        "let status = statusText(code)",
        "let restated = 1",
        "let note = \"UserDefaults and systemUptime are only named here\"",
        "print(\"a quote \\\" then mach_absolute_time\")",
        "let s = #\"UserDefaults \\(not an interpolation in a raw string)\"#",
        "let s = \"\"\"\n  systemUptime \"in\" a multi-line string\n  \"\"\"",
    ])
    func theScannerIgnoresCommentsStringsAndLookalikes(source: String) {
        #expect(Self.categories(in: source).isEmpty)
    }
}
