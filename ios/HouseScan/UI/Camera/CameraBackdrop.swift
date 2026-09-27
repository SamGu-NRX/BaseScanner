import SwiftUI

/// What sits behind every overlay: the live camera, a replayed still, or a dark placeholder.
///
/// A still is the unrotated landscape sensor image. It is shown rotated 90° clockwise and
/// scaled to fill, centered and cropped, which is exactly what `CameraProjection.viewPoint`
/// assumes, so overlays drawn from the projection line up with the picture.
struct CameraBackdrop: View {
    var feed: CameraFeed
    var actions: any ScanActions

    var body: some View {
        GeometryReader { proxy in
            switch feed {
            case .live:
                actions.liveCameraView()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            case .still(let image):
                Image(decorative: image, scale: 1, orientation: .right)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            case .none:
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
