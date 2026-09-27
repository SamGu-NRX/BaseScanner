import MetalKit
import Observation
import SwiftUI

/// Whether the live fog can draw. The shaders compile once per launch, off the main thread, as
/// soon as the app starts (`HouseScanApp`); until then, and if Metal fails, `CameraOverlays`
/// draws the frosted `FogOverlay` instead, so the camera never shows unseen wall as clear.
@MainActor
@Observable
final class LiveFogSupport {
    enum Status {
        case preparing
        case ready(LiveFogGPU)
        case failed
    }

    static let shared = LiveFogSupport()

    private(set) var status: Status = .preparing
    @ObservationIgnored private var started = false

    func prepare() {
        guard !started else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            let result: Result<LiveFogGPU, any Error>
            do { result = .success(try LiveFogGPU()) } catch { result = .failure(error) }
            await MainActor.run {
                switch result {
                case let .success(gpu):
                    LiveFogSupport.shared.status = .ready(gpu)
                case let .failure(error):
                    // Logged as an error, not trapped: a trap in a Debug build would stop every UI
                    // test, while the frosted strip in their screenshots already shows the failure.
                    RuntimeLog.engine.error("live fog unavailable, drawing the frosted strip instead: \(String(describing: error), privacy: .public)")
                    LiveFogSupport.shared.status = .failed
                }
            }
        }
    }
}

/// The fog over what coverage has not counted and, on a LiDAR phone, the dots on what depth has
/// measured: a transparent Metal layer over the camera. See `LiveFogShaders` for the look and
/// `FogValue.target` for the rule.
struct LiveFogView: UIViewRepresentable {
    let gpu: LiveFogGPU
    let input: LiveFogInput

    func makeUIView(context: Context) -> LiveFogMTKView {
        let view = LiveFogMTKView(frame: .zero, device: gpu.device)
        view.colorPixelFormat = LiveFogGPU.drawableFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        // 60, not ProMotion's 120: the pose it draws from arrives at 30 Hz, and 60 keeps each new
        // pose within one refresh of arriving.
        view.preferredFramesPerSecond = 60
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.renderer = LiveFogRenderer(gpu: gpu)
        view.renderer?.input = input
        return view
    }

    func updateUIView(_ view: LiveFogMTKView, context: Context) {
        view.renderer?.input = input
    }
}

/// An MTKView that hands each frame to its renderer. Subclassing keeps drawing on the main actor
/// without a delegate conformance.
final class LiveFogMTKView: MTKView {
    var renderer: LiveFogRenderer?

    override func draw(_ rect: CGRect) {
        guard let renderer, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        let pixels = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        guard renderer.encode(into: commandBuffer, pass: pass, size: bounds.size, pixels: pixels, pixelsPerPoint: Float(contentScaleFactor)) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
