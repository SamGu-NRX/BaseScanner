import Metal
import os
import QuartzCore
import simd

/// The compiled shaders and pipelines, made once per launch off the main thread
/// (`LiveFogSupport.prepare`). Immutable after init; Metal's devices, libraries and pipeline
/// states are safe to use from any thread.
final class LiveFogGPU: @unchecked Sendable {
    enum SetupError: Error, CustomStringConvertible {
        case noDevice
        case missing(String)

        var description: String {
            switch self {
            case .noDevice: "no Metal device"
            case let .missing(what): "Metal would not make the \(what)"
            }
        }
    }

    static let drawableFormat = MTLPixelFormat.bgra8Unorm
    /// Half floats: the blur sums eleven taps, and the fog's slow lift needs finer steps than 8 bits.
    static let maskFormat = MTLPixelFormat.rgba16Float
    static let depthFormat = MTLPixelFormat.depth32Float

    let device: MTLDevice
    let queue: MTLCommandQueue
    let mask: MTLRenderPipelineState
    let blur: MTLRenderPipelineState
    let fog: MTLRenderPipelineState
    let dots: MTLRenderPipelineState
    let depthTest: MTLDepthStencilState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.missing("command queue") }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: LiveFogShaders.source, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat, depth: Bool = false,
                      blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)? = nil) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw SetupError.missing("\(vertex) / \(fragment) functions")
            }
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            descriptor.colorAttachments[0].pixelFormat = format
            if depth { descriptor.depthAttachmentPixelFormat = Self.depthFormat }
            if let blend {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                blend(descriptor.colorAttachments[0])
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        mask = try pipeline("maskVertex", "maskFragment", format: Self.maskFormat, depth: true)
        blur = try pipeline("fullVertex", "blurFragment", format: Self.maskFormat)
        // The fog is the first thing drawn on a cleared target: premultiplied, written as is.
        fog = try pipeline("fullVertex", "fogFragment", format: Self.drawableFormat)
        // Additive light: colour adds, alpha stays, so a dot brightens the camera under it.
        dots = try pipeline("dotVertex", "dotFragment", format: Self.drawableFormat) { a in
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .zero
            a.destinationAlphaBlendFactor = .one
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthTest = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw SetupError.missing("depth state") }
        self.depthTest = depthTest
    }
}

/// What one frame of the fog draws from, all of it read from `ScanViewState`.
struct LiveFogInput {
    var projection: CameraProjection
    var wall: WallGeometry
    var coverage: CoverageStrip
    var highlight: GapRequest?
    var dots: LiveDots
    var reduceMotion: Bool
    /// The gap request's amber, sRGB.
    var requestedColor: SIMD3<Float>
}

/// Draws the fog and dots into a transparent Metal layer over the camera (`LiveFogMTKView`),
/// every display frame while the walk is on screen.
///
/// Per frame: the mask pass draws the coverage cells (`FogMaskGeometry`) into a 64-texel-wide
/// texture with a depth test, two passes blur it, then the drawable gets the fog and the dots.
/// Bounds: three frames in flight; the mask vertex ring holds 16,384 vertices a frame (a 60 m
/// strip of unmerged cells, two bands in two parts, needs about 9,600); the dot buffers hold `DotTimeline.capacity` dots
/// and are rewritten only when the field changes or a fading dot ends, at most once a frame.
/// Nothing grows with time: about 4.5 MB of buffers and 0.1 MB of textures, allocated once.
@MainActor
final class LiveFogRenderer {
    private let gpu: LiveFogGPU
    /// Seconds on the clock the animations run on. Replaceable so an offscreen render can step
    /// time; the view leaves it on the display's media clock.
    var clock: () -> Double = { CACurrentMediaTime() }
    private var epoch: Double?
    private let inFlight = DispatchSemaphore(value: LiveFogRenderer.framesInFlight)
    private static let framesInFlight = 3
    private static let maskWidth = 64
    private static let maskVertexCapacity = 16_384
    private static let spriteCapacity = DotTimeline.capacity * 2

    var input: LiveFogInput?
    var queue: MTLCommandQueue { gpu.queue }

    private let animator = FogCellAnimator()
    private let timeline = DotTimeline()
    private var maskBuffers: [MTLBuffer] = []
    private var spriteBuffers: [MTLBuffer] = []
    private var frame = 0
    private var spriteBuffer = 0
    private var spriteCount = 0
    private var maskTextures: (mask: MTLTexture, horizontal: MTLTexture, final: MTLTexture, depth: MTLTexture)?
    private var anchor: (point: SIMD2<Float>, scale: Float)?

    init(gpu: LiveFogGPU) {
        self.gpu = gpu
        for _ in 0..<Self.framesInFlight {
            if let buffer = gpu.device.makeBuffer(length: Self.maskVertexCapacity * MemoryLayout<FogMaskGeometry.Vertex>.stride, options: .storageModeShared) {
                maskBuffers.append(buffer)
            }
            if let buffer = gpu.device.makeBuffer(length: Self.spriteCapacity * MemoryLayout<DotTimeline.Sprite>.stride, options: .storageModeShared) {
                spriteBuffers.append(buffer)
            }
        }
        if maskBuffers.count < Self.framesInFlight || spriteBuffers.count < Self.framesInFlight {
            RuntimeLog.engine.error("live fog: Metal would not allocate its buffers; nothing will draw")
        }
    }

    /// Encodes one frame into `pass`, whose target is `pixels` in size for a view of `size`
    /// points. Returns false, encoding nothing, when all three frames are still in flight: the
    /// caller skips the frame rather than block the main thread on the GPU. `LiveFogMTKView`
    /// calls this each display frame.
    func encode(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, pixels: SIMD2<Float>, pixelsPerPoint scale: Float) -> Bool {
        guard let input, maskBuffers.count == Self.framesInFlight, spriteBuffers.count == Self.framesInFlight,
              size.width > 1, size.height > 1 else { return false }
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let textures = textures(for: size) else {
            inFlight.signal()
            return false
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let start = epoch ?? clock()
        epoch = start
        let now = clock() - start
        let time = Float(now)
        let slot = frame % Self.framesInFlight
        frame &+= 1

        var clip = Self.clipMatrix(input.projection, size: size)
        let maskBuffer = maskBuffers[slot]
        let maskCount = FogMaskGeometry.build(
            coverage: input.coverage, wall: input.wall, highlight: input.highlight, animator: animator,
            now: now, reduceMotion: input.reduceMotion,
            into: maskBuffer.contents().bindMemory(to: FogMaskGeometry.Vertex.self, capacity: Self.maskVertexCapacity),
            capacity: Self.maskVertexCapacity)

        let changed = timeline.update(input.dots, now: time)
        let expired = timeline.expire(now: time)
        if changed || expired {
            spriteBuffer = (spriteBuffer + 1) % Self.framesInFlight
            let buffer = spriteBuffers[spriteBuffer]
            spriteCount = timeline.write(into: buffer.contents().bindMemory(to: DotTimeline.Sprite.self, capacity: Self.spriteCapacity), capacity: Self.spriteCapacity)
        }

        // Mask: full fog wherever no cell reaches.
        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture = textures.mask
        maskPass.colorAttachments[0].loadAction = .clear
        maskPass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 0)
        maskPass.colorAttachments[0].storeAction = .store
        maskPass.depthAttachment.texture = textures.depth
        maskPass.depthAttachment.loadAction = .clear
        maskPass.depthAttachment.clearDepth = 1
        maskPass.depthAttachment.storeAction = .dontCare
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass) {
            if maskCount > 0 {
                encoder.setRenderPipelineState(gpu.mask)
                encoder.setDepthStencilState(gpu.depthTest)
                encoder.setVertexBuffer(maskBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&clip, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: maskCount)
            }
            encoder.endEncoding()
        }
        for (source, target, direction) in [(textures.mask, textures.horizontal, SIMD2<Int32>(1, 0)), (textures.horizontal, textures.final, SIMD2<Int32>(0, 1))] {
            let blurPass = MTLRenderPassDescriptor()
            blurPass.colorAttachments[0].texture = target
            blurPass.colorAttachments[0].loadAction = .dontCare
            blurPass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: blurPass) else { continue }
            var direction = direction
            encoder.setRenderPipelineState(gpu.blur)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            let pin = anchor(input, size: size, pixelsPerPoint: scale)
            var fog = FogUniforms(
                viewSize: pixels, anchor: pin.point, anchorScale: pin.scale, time: time,
                motion: input.reduceMotion ? 0 : 1, pad: 0, requested: SIMD4(input.requestedColor, 1))
            encoder.setRenderPipelineState(gpu.fog)
            encoder.setFragmentBytes(&fog, length: MemoryLayout<FogUniforms>.stride, index: 0)
            encoder.setFragmentTexture(textures.final, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if spriteCount > 0 {
                var dots = DotUniforms(
                    clip: clip, cameraAndTime: SIMD4(input.projection.cameraPosition, time),
                    pointScale: scale, reduceMotion: input.reduceMotion ? 1 : 0, pad: .zero)
                encoder.setRenderPipelineState(gpu.dots)
                encoder.setVertexBuffer(spriteBuffers[spriteBuffer], offset: 0, index: 0)
                encoder.setVertexBytes(&dots, length: MemoryLayout<DotUniforms>.stride, index: 1)
                encoder.setVertexTexture(textures.final, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: spriteCount)
            }
            encoder.endEncoding()
        }
        return true
    }

    /// The mask keeps the view's aspect at 64 texels across, about 6 points a texel on a phone,
    /// so the blur's sigma is about 15 points: the prototype's 96 texels left cell columns reading
    /// as strips in the offscreen preview. The noise-warped lookup (`fogFragment`) ragged the rest.
    private func textures(for size: CGSize) -> (mask: MTLTexture, horizontal: MTLTexture, final: MTLTexture, depth: MTLTexture)? {
        let width = Self.maskWidth
        let height = max(1, Int((Double(width) * size.height / size.width).rounded()))
        if let maskTextures, maskTextures.mask.width == width, maskTextures.mask.height == height { return maskTextures }
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = .private
            return gpu.device.makeTexture(descriptor: descriptor)
        }
        guard let mask = texture(LiveFogGPU.maskFormat, [.renderTarget, .shaderRead]),
              let horizontal = texture(LiveFogGPU.maskFormat, [.renderTarget, .shaderRead]),
              let final = texture(LiveFogGPU.maskFormat, [.renderTarget, .shaderRead]),
              let depth = texture(LiveFogGPU.depthFormat, [.renderTarget]) else {
            RuntimeLog.engine.error("live fog: Metal would not allocate the mask textures")
            return nil
        }
        maskTextures = (mask, horizontal, final, depth)
        return maskTextures
    }

    /// Where the fog's noise is pinned: the meter on screen, one noise unit about 1.2 m at the
    /// meter's distance, so the texture moves and scales with the wall. Kept from the last frame
    /// that saw the meter in front of the camera.
    private func anchor(_ input: LiveFogInput, size: CGSize, pixelsPerPoint: Float) -> (point: SIMD2<Float>, scale: Float) {
        let width = Float(size.width) * pixelsPerPoint
        let local = input.projection.cameraSpace(input.wall.meter)
        if local.z < -0.1, let point = input.projection.viewPoint(for: input.wall.meter, in: size) {
            let pointsPerMeter = input.projection.intrinsics.x * Float(input.projection.scale(in: size)) / -local.z
            let scale = min(max(pointsPerMeter * pixelsPerPoint * 1.2, 0.25 * width), 2 * width)
            anchor = (SIMD2(Float(point.x), Float(point.y)) * pixelsPerPoint, scale)
        }
        return anchor ?? (.zero, 0.45 * width)
    }

    /// World to Metal clip space for a portrait view of `size` showing the landscape sensor image
    /// turned 90 degrees clockwise and scaled to fill, the mapping `CameraProjection.viewPoint`
    /// uses. Depth runs from 0 at 5 cm to 1 at 100 m, so the GPU clips anything behind the camera
    /// and the mask's depth test keeps the nearest surface.
    static func clipMatrix(_ projection: CameraProjection, size: CGSize, near: Float = 0.05, far: Float = 100) -> simd_float4x4 {
        let k = projection.intrinsics
        let imageHeight = projection.imageSize.y
        let scale = Float(projection.scale(in: size))
        let width = Float(size.width), height = Float(size.height)
        let offset = SIMD2(
            (width - projection.imageSize.y * scale) / 2,
            (height - projection.imageSize.x * scale) / 2)
        // Rows act on camera-space (x, y, z, 1); w is the depth along -z.
        let w = SIMD4<Float>(0, 0, -1, 0)
        let portraitX = SIMD4<Float>(0, k.y, k.w - imageHeight, 0)
        let portraitY = SIMD4<Float>(k.x, 0, -k.z, 0)
        let screenX = offset.x * w + scale * portraitX
        let screenY = offset.y * w + scale * portraitY
        let clipX = (2 / width) * screenX - w
        let clipY = w - (2 / height) * screenY
        let clipZ = SIMD4<Float>(0, 0, -far / (far - near), -far * near / (far - near))
        let cameraToClip = simd_float4x4(rows: [clipX, clipY, clipZ, w])
        return cameraToClip * projection.cameraToWorld.inverse
    }
}

/// Matches `FogUniforms` in the shader.
struct FogUniforms {
    var viewSize: SIMD2<Float>
    var anchor: SIMD2<Float>
    var anchorScale: Float
    var time: Float
    var motion: Float
    var pad: Float
    var requested: SIMD4<Float>
}

/// Matches `DotUniforms` in the shader.
struct DotUniforms {
    var clip: simd_float4x4
    var cameraAndTime: SIMD4<Float>
    var pointScale: Float
    var reduceMotion: Float
    var pad: SIMD2<Float>
}
