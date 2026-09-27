import LiveDotsCore
import Metal
import MetalKit
import simd

/// What one frame shows: which keyframe, when on the playback clock, and the toggles.
struct FrameRequest: Equatable {
    var mode: CaptureMode
    var keyframe: Int
    /// Playback seconds; animations are evaluated at this time.
    var time: Float
    var reduceMotion: Bool
    var showFog: Bool
}

/// Draws a keyframe: the camera image, the optional fog veil, then the dots as additive point
/// sprites from one vertex buffer. The buffer is rebuilt only when the keyframe or mode changes;
/// between keyframes the shader animates births and evidence from the playback time.
final class DotRenderer {
    enum SetupError: Error, CustomStringConvertible {
        case noMetalDevice
        case noCommandQueue
        case buffer(String)

        var description: String {
            switch self {
            case .noMetalDevice: "no Metal device on this Mac"
            case .noCommandQueue: "Metal would not make a command queue"
            case let .buffer(what): "Metal would not allocate the \(what) buffer"
            }
        }
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: MTLDevice
    let queue: MTLCommandQueue
    let data: ReplayData
    private let cameraPipeline: MTLRenderPipelineState
    private let veilPipeline: MTLRenderPipelineState
    private let dotPipeline: MTLRenderPipelineState
    private let cameraImages: [MTLTexture]

    private var spriteBuffer: MTLBuffer?
    private var spriteCount = 0
    private var veilBuffer: MTLBuffer?
    private var veilVertexCount = 0
    private var cachedKey: (mode: CaptureMode, keyframe: Int)?
    /// Replaces the timeline's sprites, for the 6,000-dot benchmark.
    var spriteOverride: [DotSprite]? {
        didSet { cachedKey = nil }
    }

    init(data: ReplayData, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw SetupError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.noCommandQueue }
        self.device = device
        self.queue = queue
        self.data = data

        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            blend(descriptor.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        cameraPipeline = try pipeline("cameraVertex", "cameraFragment") { _ in }
        veilPipeline = try pipeline("veilVertex", "veilFragment") { a in
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .zero
            a.destinationAlphaBlendFactor = .one
        }
        // Additive: the dots are light on the camera image, never paint over it.
        dotPipeline = try pipeline("dotVertex", "dotFragment") { a in
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .zero
            a.destinationAlphaBlendFactor = .one
        }

        let loader = MTKTextureLoader(device: device)
        cameraImages = try data.replay.keyframes.map { keyframe in
            try loader.newTexture(
                URL: data.replay.folder.appendingPathComponent(keyframe.imagePath),
                options: [.SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue])
        }
    }

    /// Encodes one frame into `pass`, whose target is `pixelSize` pixels at `pointScale` pixels
    /// per point.
    func encode(_ request: FrameRequest, into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                pixelSize: SIMD2<Float>, pointScale: Float) throws {
        let state = data.timeline(request.mode).states[request.keyframe]
        let keyframe = data.replay.keyframes[request.keyframe]
        try prepareBuffers(request.mode, state)
        let projection = ScreenProjection(keyframe: keyframe, viewSize: pixelSize)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        var camera = CameraUniforms(
            offset: projection.offset, scale: projection.scale, pad: 0,
            imageSize: SIMD2(Float(keyframe.width), Float(keyframe.height)))
        encoder.setRenderPipelineState(cameraPipeline)
        encoder.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        encoder.setFragmentTexture(cameraImages[request.keyframe], index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        var clip = projection.clipMatrix
        if request.showFog, let veilBuffer, veilVertexCount > 0 {
            encoder.setRenderPipelineState(veilPipeline)
            encoder.setVertexBuffer(veilBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&clip, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: veilVertexCount)
        }

        if let spriteBuffer, spriteCount > 0 {
            var dots = DotUniforms(
                clip: clip, cameraAndTime: SIMD4(keyframe.cameraPosition, request.time),
                pointScale: pointScale, reduceMotion: request.reduceMotion ? 1 : 0, pad: .zero)
            encoder.setRenderPipelineState(dotPipeline)
            encoder.setVertexBuffer(spriteBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&dots, length: MemoryLayout<DotUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: spriteCount)
        }
    }

    private func prepareBuffers(_ mode: CaptureMode, _ state: KeyframeState) throws {
        if let cachedKey, cachedKey.mode == mode, cachedKey.keyframe == state.index { return }
        cachedKey = (mode, state.index)

        let vertices = Self.vertices(for: spriteOverride ?? state.sprites)
        spriteCount = vertices.count
        spriteBuffer = vertices.isEmpty ? nil : try makeBuffer(vertices, "dot")

        var veil: [SIMD4<Float>] = []
        for cell in state.unseenCells {
            let (x0, y0, s) = (cell.minX, cell.minY, WallCell.size)
            let a = SIMD4<Float>(x0, y0, 0, 1), b = SIMD4<Float>(x0 + s, y0, 0, 1)
            let c = SIMD4<Float>(x0 + s, y0 + s, 0, 1), d = SIMD4<Float>(x0, y0 + s, 0, 1)
            veil += [a, b, c, a, c, d]
        }
        veilVertexCount = veil.count
        veilBuffer = veil.isEmpty ? nil : try makeBuffer(veil, "veil")
    }

    private func makeBuffer<T>(_ items: [T], _ what: String) throws -> MTLBuffer {
        let buffer = items.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
        }
        guard let buffer else { throw SetupError.buffer(what) }
        return buffer
    }

    /// One vertex per dot, plus a halo vertex (3x size, 12% opacity) under every edge dot. Halos
    /// come first so the sharp dots sit on top of them.
    static func vertices(for sprites: [DotSprite]) -> [SpriteVertex] {
        var halos: [SpriteVertex] = [], dots: [SpriteVertex] = []
        halos.reserveCapacity(sprites.count / 4)
        dots.reserveCapacity(sprites.count)
        for sprite in sprites {
            let vertex = SpriteVertex(sprite)
            dots.append(vertex)
            if sprite.edgeSince < .infinity { halos.append(vertex.asHalo) }
        }
        return halos + dots
    }
}

/// Matches `Sprite` in the shader. Infinite times are clamped to plus or minus 1e6 s, because
/// Metal compiles with fast math, which assumes no infinities.
struct SpriteVertex {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>

    init(_ s: DotSprite) {
        func finite(_ t: Float) -> Float { min(max(t, -1e6), 1e6) }
        let size: Float = switch s.kind {
        case .feature: -4
        case .flat, .edge, .plane: 2.5
        }
        a = SIMD4(s.position, size)
        b = SIMD4(finite(s.birthTime), s.fromOpacity, s.toOpacity, finite(s.opacityTime))
        c = SIMD4(finite(s.edgeSince), finite(s.deathTime), s.onOccluder ? 1 : 0, s.kind == .feature ? 1 : 0)
    }

    var asHalo: SpriteVertex {
        var halo = self
        halo.c.w = 2
        return halo
    }
}

struct CameraUniforms {
    var offset: SIMD2<Float>
    var scale: Float
    var pad: Float
    var imageSize: SIMD2<Float>
}

struct DotUniforms {
    var clip: simd_float4x4
    var cameraAndTime: SIMD4<Float>
    var pointScale: Float
    var reduceMotion: Float
    var pad: SIMD2<Float>
}
