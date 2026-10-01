import CoreGraphics
import HouseScanKit
import Testing

/// The folded find-meter aim (`OpenCameraAim`): the middle of the open camera's part on screen,
/// or nil for the middle of the screen.
@Suite struct OpenCameraAimTests {
    /// An iPhone 17's camera view, in points.
    private static let camera = CGSize(width: 402, height: 874)

    @Test func anUnfoldedCardAimsAtTheMiddleOfTheScreen() {
        let window = CGRect(x: 0, y: 420, width: 402, height: 220)
        #expect(OpenCameraAim.point(folds: false, window: window, camera: Self.camera) == nil)
    }

    @Test func noMeasuredWindowAimsAtTheMiddleOfTheScreen() {
        #expect(OpenCameraAim.point(folds: true, window: nil, camera: Self.camera) == nil)
    }

    @Test func aWindowWhollyOnScreenAimsAtItsMiddle() {
        let window = CGRect(x: 16, y: 420, width: 370, height: 220)
        #expect(OpenCameraAim.point(folds: true, window: window, camera: Self.camera) == CGPoint(x: 201, y: 530))
    }

    /// What the chrome measures: its open camera is a Spacer, which can be zero points wide.
    /// Rejecting that put the reticle back under the card at AX5 (run 36877327250).
    @Test func theChromesZeroWidthSpacerAimsAtItsMiddle() {
        let window = CGRect(x: 201, y: 420, width: 0, height: 220)
        #expect(OpenCameraAim.point(folds: true, window: window, camera: Self.camera) == CGPoint(x: 201, y: 530))
    }

    /// Scrolled down, the window's top leaves the screen and the aim follows what is left.
    @Test func aWindowCutAtTheTopAimsAtItsPartOnScreen() {
        let window = CGRect(x: 16, y: -100, width: 370, height: 300)
        #expect(OpenCameraAim.point(folds: true, window: window, camera: Self.camera) == CGPoint(x: 201, y: 100))
    }

    @Test func aWindowCutAtTheBottomAimsAtItsPartOnScreen() {
        let window = CGRect(x: 16, y: 774, width: 370, height: 300)
        #expect(OpenCameraAim.point(folds: true, window: window, camera: Self.camera) == CGPoint(x: 201, y: 824))
    }

    @Test(arguments: [
        CGRect(x: 16, y: -400, width: 370, height: 300),
        CGRect(x: 16, y: 874, width: 370, height: 200),
        CGRect(x: 16, y: 500, width: 370, height: 0),
    ])
    func noWindowOnScreenAimsAtTheMiddleOfTheScreen(window: CGRect) {
        #expect(OpenCameraAim.point(folds: true, window: window, camera: Self.camera) == nil)
    }
}
