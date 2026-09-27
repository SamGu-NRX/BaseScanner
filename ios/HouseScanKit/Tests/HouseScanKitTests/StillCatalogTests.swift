import HouseScanKit
import Testing

/// The meter close-up through saves, rejections, a skip and a confirmation (#112). Only a photo
/// the homeowner accepted stands for the meter; a rejected one stays a plain photo.
@Suite struct StillCatalogTests {
    /// A saved photo is not the meter's photo until the homeowner confirms the number read from
    /// it. Before, saving alone listed it in scene.json and linked it to the meter mark.
    @Test func aSavedStillIsNotAcceptedUntilConfirmed() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        #expect(!catalog.isAccepted("meter_close"))
        #expect(catalog.acceptedFileNames.isEmpty)
        #expect(catalog.frames == ["meter_close": 1])
        #expect(catalog.accept("meter_close"))
        #expect(catalog.isAccepted("meter_close"))
        #expect(catalog.acceptedFileNames == ["meter_close": "meter_close.jpg"])
    }

    /// A rejected shot (no number read, "None of these") is never accepted; the retake's photo
    /// replaces it, and only the confirmed retake stands for the meter.
    @Test func aRejectedShotThenARetakeAcceptsOnlyTheRetake() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        // Rejected: nothing accepts it. The photo stays a plain photo until the retake.
        #expect(catalog.acceptedFileNames.isEmpty)
        #expect(catalog.frames == ["meter_close": 1])
        catalog.save(2, purpose: "meter_close", fileName: "meter_close.jpg")
        #expect(catalog.accept("meter_close"))
        #expect(catalog.frames == ["meter_close": 2])
        #expect(catalog.acceptedFileNames == ["meter_close": "meter_close.jpg"])
    }

    /// Skipping after a rejected shot leaves no accepted photo, and the photo stays in the
    /// packet's photos as a plain photo.
    @Test func aSkipAfterARejectionAcceptsNothing() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        catalog.withdraw("meter_close")
        #expect(!catalog.isAccepted("meter_close"))
        #expect(catalog.acceptedFileNames.isEmpty)
        #expect(catalog.frames == ["meter_close": 1])
    }

    /// A skip after a confirmation withdraws it.
    @Test func aSkipWithdrawsAnAcceptance() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        catalog.accept("meter_close")
        catalog.withdraw("meter_close")
        #expect(catalog.acceptedFileNames.isEmpty)
    }

    /// A new photo saved over an accepted one is not accepted: the acceptance was for the old one.
    @Test func aNewSaveDropsTheOldAcceptance() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        catalog.accept("meter_close")
        catalog.save(2, purpose: "meter_close", fileName: "meter_close.jpg")
        #expect(!catalog.isAccepted("meter_close"))
        #expect(catalog.acceptedFileNames.isEmpty)
    }

    /// Nothing saved, nothing to accept.
    @Test func acceptingWithoutASaveFails() {
        var catalog = StillCatalog<Int>()
        #expect(!catalog.accept("meter_close"))
        #expect(catalog.acceptedFileNames.isEmpty)
    }

    /// Discarding the stills (a new world frame) hands back every file, accepted or not.
    @Test func removeAllReturnsEveryFile() {
        var catalog = StillCatalog<Int>()
        catalog.save(1, purpose: "meter_close", fileName: "meter_close.jpg")
        catalog.save(2, purpose: "panel_wall", fileName: "panel_wall.jpg")
        catalog.accept("panel_wall")
        #expect(catalog.removeAll() == ["meter_close.jpg", "panel_wall.jpg"])
        #expect(catalog.frames.isEmpty && catalog.acceptedFileNames.isEmpty)
    }
}
