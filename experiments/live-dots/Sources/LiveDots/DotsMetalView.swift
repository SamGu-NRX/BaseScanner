import AppKit
import MetalKit
import SwiftUI

/// The camera image and dots, drawn by `DotRenderer` into an MTKView at the display's rate.
struct DotsMetalView: NSViewRepresentable {
    let renderer: DotRenderer
    let player: ReplayPlayer
    let timer: FrameTimer

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, player: player, timer: timer)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = DotRenderer.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: DotRenderer
        let player: ReplayPlayer
        let timer: FrameTimer

        init(renderer: DotRenderer, player: ReplayPlayer, timer: FrameTimer) {
            self.renderer = renderer
            self.player = player
            self.timer = timer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            player.tick(now: CACurrentMediaTime())
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = renderer.queue.makeCommandBuffer()
            else { return }
            let start = CACurrentMediaTime()
            let request = player.request
            do {
                try renderer.encode(
                    request, into: commandBuffer, pass: pass,
                    pixelSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                    pointScale: Float(view.window?.backingScaleFactor ?? 2))
            } catch {
                assertionFailure("frame encode failed: \(error)")
            }
            commandBuffer.present(drawable)
            let cpu = CACurrentMediaTime() - start
            let sprites = renderer.data.timeline(request.mode).states[request.keyframe].sprites.count
            let timer = timer
            commandBuffer.addCompletedHandler { buffer in
                timer.record(cpuSeconds: cpu, gpuSeconds: buffer.gpuEndTime - buffer.gpuStartTime, sprites: sprites)
            }
            commandBuffer.commit()
        }
    }
}
