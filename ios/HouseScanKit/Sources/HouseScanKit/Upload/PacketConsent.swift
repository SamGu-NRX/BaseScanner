import Foundation

/// The words of the consent screen, and the id sent with the homeowner's yes. The id
/// names this exact text: `PacketUploadTests.consentWordingIsPinnedToItsID` fails when a word
/// changes and the id doesn't, since the server would then hold a consent for words no one saw.
/// The screen may add numbers (how many photos, how many MB) around the text; it never rewords it.
public struct PacketConsentWording: Sendable, Equatable {
    public let id: String
    public let title: String
    public let intro: String
    public let sentHeading: String
    /// What is sent, one line each.
    public let photos: String
    public let measurements: String
    public let threeD: String
    /// Who gets it.
    public let recipient: String
    public let optional: String
    /// The toggle's label: agreeing to it is the consent.
    public let agreement: String
    public let send: String
    public let skip: String

    public static let current = PacketConsentWording(
        id: "packet-consent-1",
        title: "Send your scan to Base's survey team?",
        intro: "It helps them build a 3D model of your wall.",
        sentHeading: "What's sent",
        photos: "Photos of your wall and meter",
        measurements: "Measurements of your wall, your marks and the path you walked",
        threeD: "3D data: depth and your wall's shape, if your phone recorded them",
        recipient: "It goes to Base's survey team.",
        optional: "Sending is optional. Your result stays the same if you skip.",
        agreement: "Send my photos, measurements and 3D data to Base's survey team",
        send: "Send",
        skip: "Skip"
    )

    /// SHA-256 of every string above, in order, one per line.
    public var fingerprint: String {
        let text = [title, intro, sentHeading, photos, measurements, threeD, recipient, optional, agreement, send, skip].joined(separator: "\n")
        return PacketFiles.sha256(Data(text.utf8))
    }
}

/// The consent screen's one input. The toggle starts off and nothing pre-checks it; Send is
/// enabled only while it is on, and only then is there a consent to send.
public struct PacketConsentForm: Sendable, Equatable {
    public var agreed = false

    public init() {}

    public var canSend: Bool { agreed }

    /// The consent to record, stamped `at` the moment Send was pressed; nil while not agreed.
    public func consent(_ wording: PacketConsentWording = .current, at time: Date) -> PacketUploadConsent? {
        agreed ? PacketUploadConsent(grantedAt: time, textID: wording.id) : nil
    }
}
