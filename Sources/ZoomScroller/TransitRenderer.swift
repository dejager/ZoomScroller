import Foundation
import MetalKit

enum TransitRenderError: LocalizedError {
    case allocation
    case shader(String)

    var errorDescription: String? {
        switch self {
        case .allocation: return "Metal could not allocate a rendering resource."
        case .shader(let name): return "The ZoomScroller shader \(name) is missing."
        }
    }
}

@MainActor
final class TransitRenderer {
    static let targetFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let hold, exposure, stroke, type: MTLRenderPipelineState

    // Keep field order and SIMD alignment in sync with Transit.metal.
    private struct Mapping {
        var crop, rowX, rowY: SIMD4<Float>
        init(_ frame: TransitFrame, viewport: SIMD2<Float>) {
            let ratio = viewport.x / viewport.y / max(0.0001, frame.aspect)
            let fill = SIMD2(min(1, ratio), min(1, 1 / ratio))
            let m = frame.uvTransform
            rowX = SIMD4(Float(m.a), Float(m.c), Float(m.tx), 0)
            rowY = SIMD4(Float(m.b), Float(m.d), Float(m.ty), 0)
            let texels = SIMD2(Float(frame.texture.width), Float(frame.texture.height))
            let dx = SIMD2(rowX.x, rowY.x) * texels * (fill.x / viewport.x)
            let dy = SIMD2(rowX.y, rowY.y) * texels * (fill.y / viewport.y)
            let footprint = max(simd_length(dx), simd_length(dy))
            crop = SIMD4(fill.x, fill.y, log2(max(0.0001, footprint)), 0)
        }
    }
    private struct Print {
        var viewport, finish: SIMD4<Float>
        var from, to: Mapping
        var brightness: Float
    }
    private struct Tap {
        var from = SIMD4<Float>.zero
        var to = SIMD4<Float>.zero
        var mix = SIMD4<Float>.zero
    }
    private struct Ink {
        var geometry, viewport: SIMD4<Float>
        var label = SIMD4<Float>.zero
        var brightness: Float
    }
    private var taps = Array(repeating: Tap(), count: 7)
    private var artwork: [TransitArtwork] = []

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw TransitRenderError.allocation }
        self.queue = queue
        let library = try device.makeDefaultLibrary(bundle: .module)
        func pipeline(_ vertex: String, _ fragment: String, blended: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            guard let v = library.makeFunction(name: vertex) else { throw TransitRenderError.shader(vertex) }
            guard let f = library.makeFunction(name: fragment) else { throw TransitRenderError.shader(fragment) }
            descriptor.label = fragment
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = Self.targetFormat
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        hold = try pipeline("transitScreen", "transitHold")
        exposure = try pipeline("transitScreen", "transitExposure")
        stroke = try pipeline("transitStroke", "transitHairline", blended: true)
        type = try pipeline("transitTypeQuad", "transitType", blended: true)
    }

    /// Warming the immediate neighbors amortizes label rasterization across feed navigation.
    func prepare(items: ArraySlice<ZoomScrollerItem>, overlays: ZoomScrollerOverlays) throws {
        artwork.removeAll { entry in !items.contains(entry.item) }
        for item in items { _ = try decorations(for: item, overlays: overlays) }
    }

    private func decorations(for item: ZoomScrollerItem, overlays: ZoomScrollerOverlays) throws -> TransitArtwork {
        if let cached = artwork.first(where: { $0.item == item }) {
            try cached.prepare(overlays, device: device)
            return cached
        }
        let entry = TransitArtwork(item)
        try entry.prepare(overlays, device: device)
        if artwork.count == 4 { artwork.removeFirst() }
        artwork.append(entry)
        return entry
    }

    @discardableResult
    func draw(
        in view: MTKView, from: ZoomScrollerItem, to: ZoomScrollerItem, progress: Float,
        edgeStretch: Float = 0, edgeLensGain: Float = 1,
        first: TransitFrame, second: TransitFrame, style: ZoomScrollerStyle
    ) throws -> Bool {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return false }
        guard let command = queue.makeCommandBuffer() else { throw TransitRenderError.allocation }
        try encode(
            pass: pass, scale: Float(view.contentScaleFactor), command: command,
            from: from, to: to, progress: progress, edgeStretch: edgeStretch, edgeLensGain: edgeLensGain,
            first: first, second: second, style: style)
        command.present(drawable)
        command.commit()
        return true
    }

    /// Shared by the live drawable and offscreen regression renders. The caller owns submission.
    func encode(
        pass: MTLRenderPassDescriptor, scale: Float, command: MTLCommandBuffer,
        from: ZoomScrollerItem, to: ZoomScrollerItem, progress: Float,
        edgeStretch: Float = 0, edgeLensGain: Float = 1,
        first: TransitFrame, second: TransitFrame, style: ZoomScrollerStyle
    ) throws {
        let progress = min(1, max(0, progress))
        let singleItem = progress == 0 || progress == 1 || from.id == to.id
        let edge = singleItem ? edgeStretch : 0
        let parked = singleItem && edge == 0
        // Below the first stop, rewind the arriving camera from t=1. Above
        // the last stop, advance the departing camera from t=0.
        let lensTravel = edge * edgeLensGain
        let p = edge == 0 ? progress : (edge < 0 ? 1 + lensTravel : lensTravel)
        let brightness = exp2(-1.6 * abs(edge))
        let item = progress == 1 ? to : from
        let media = progress == 1 ? second : first
        let outgoing = try decorations(for: item, overlays: style.overlays)
        let incoming = singleItem ? outgoing : try decorations(for: to, overlays: style.overlays)
        guard let target = pass.colorAttachments[0].texture,
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { throw TransitRenderError.allocation }
        let viewport = SIMD2(Float(target.width), Float(target.height))
        let dimensions = SIMD4(viewport.x, viewport.y, min(viewport.x, viewport.y), scale)
        let flags = (style.overlays.contains(.dust) ? 1 : 0) + (style.overlays.contains(.dirt) ? 2 : 0)
        let map = Mapping(media, viewport: viewport)
        var print = Print(
            viewport: dimensions,
            finish: SIMD4(parked ? 0 : p, outgoing.seed, incoming.seed, Float(flags)),
            from: map, to: singleItem ? map : Mapping(second, viewport: viewport), brightness: brightness)
        encoder.setFragmentBytes(&print, length: MemoryLayout<Print>.stride, index: 0)
        encoder.setFragmentTexture(media.texture, index: 0)
        if parked {
            encoder.setRenderPipelineState(hold)
        } else {
            encoder.setRenderPipelineState(exposure)
            encoder.setFragmentTexture(singleItem ? media.texture : second.texture, index: 1)
            let fixedArrival: Float? = edge == 0 ? nil : (edge < 0 ? 1 : 0)
            let count = makeExposure(progress: p, style: style, fixedArrival: fixedArrival)
            taps.withUnsafeBufferPointer { samples in
                encoder.setFragmentBytes(samples.baseAddress!, length: count * MemoryLayout<Tap>.stride, index: 1)
            }
            var sampleCount = UInt32(count)
            encoder.setFragmentBytes(&sampleCount, length: MemoryLayout<UInt32>.size, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if parked {
            decorate(
                outgoing, dolly: 0, roll: 0, opacity: 1, typeOpacity: 1,
                size: dimensions, overlays: style.overlays, on: encoder)
        } else {
            let poses = Self.pose(p, distortion: style.distortion)
            let fade = Self.smoothstep((p - 0.28) / 0.45)
            if edge >= 0 {
                decorate(
                    outgoing, dolly: 1 - poses.from.x, roll: -asin(poses.from.z), opacity: 1 - fade,
                    typeOpacity: 1 - Self.smoothstep((p - 0.18) / 0.27),
                    size: dimensions, brightness: brightness, overlays: style.overlays, on: encoder)
            }
            if edge <= 0 {
                decorate(
                    incoming, dolly: 1 - poses.to.x, roll: -asin(poses.to.z), opacity: fade,
                    typeOpacity: Self.smoothstep((p - 0.49) / 0.30),
                    size: dimensions, brightness: brightness, overlays: style.overlays, on: encoder)
            }
        }
        encoder.endEncoding()
        // CVMetalTexture-backed video images hold a buffer-pool lease through GPU completion.
        command.addCompletedHandler { [first, second] _ in
            withExtendedLifetime((first, second)) {}
        }
    }

    private static func smoothstep(_ t: Float) -> Float {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    /// Each camera moves forward. The outgoing exposure remains on the wider lens while
    /// the incoming camera approaches its resting focal length from farther back.
    private static func pose(_ p: Float, distortion: Float) -> Tap {
        let travel = smoothstep(p)
        let pulse = sin(.pi * p)
        let roll = 0.060 * pulse * pulse * distortion
        let remaining = 1 - travel
        // For r² <= 1, (1 + .84u)/sqrt(1 + 1.60u*r²) is increasing in u.
        // Pair magnification with the relaxing lens so even the rim continues forward.
        return Tap(
            from: SIMD4(exp2(-1.66 * travel), cos(roll), sin(roll), 1.78 * travel * distortion),
            to: SIMD4(1 + 0.84 * remaining, cos(-roll), sin(-roll), 1.60 * remaining * distortion),
            mix: SIMD4(p, 1, 0, 0))
    }

    private func makeExposure(progress: Float, style: ZoomScrollerStyle, fixedArrival: Float?) -> Int {
        // The shutter samples the timeline itself, so holding or reversing a gesture is exact.
        let span = style.shutter * 0.098 * sin(.pi * progress)
        let count = style.shutter == 0 ? 1 : taps.count
        for i in 0..<count {
            let offset = (Float(i) + 0.5) / Float(count) - 0.5
            var sample = Self.pose(min(1, max(0, progress + offset * span)), distortion: style.distortion)
            if let fixedArrival { sample.mix.x = fixedArrival }
            sample.mix.y = 1 / Float(count)
            taps[i] = sample
        }
        return count
    }

    private func decorate(
        _ art: TransitArtwork, dolly: Float, roll: Float, opacity: Float, typeOpacity: Float,
        size: SIMD4<Float>, brightness: Float = 1,
        overlays: ZoomScrollerOverlays, on encoder: MTLRenderCommandEncoder
    ) {
        guard opacity > 0 else { return }
        var ink = Ink(geometry: SIMD4(dolly, roll, 0.38 * opacity, max(0.43, 0.32 * size.w)),
                      viewport: size, brightness: brightness)
        func uniforms() {
            encoder.setVertexBytes(&ink, length: MemoryLayout<Ink>.stride, index: 0)
            encoder.setFragmentBytes(&ink, length: MemoryLayout<Ink>.stride, index: 0)
        }
        func drawMesh(_ mesh: TransitArtwork.Strokes?) {
            guard let mesh else { return }
            encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 130, instanceCount: mesh.count)
        }
        if overlays.contains(.curves) && art.curves != nil || overlays.contains(.squiggles) && art.squiggles != nil {
            encoder.setRenderPipelineState(stroke)
            uniforms()
            if overlays.contains(.curves) { drawMesh(art.curves) }
            if overlays.contains(.squiggles) { drawMesh(art.squiggles) }
        }
        let label = overlays.contains(.labels) ? art.label : nil
        let text = overlays.contains(.text) ? art.text : nil
        guard typeOpacity > 0, label != nil || text != nil else { return }
        encoder.setRenderPipelineState(type)
        ink.geometry.z = typeOpacity
        // A single scale controls both axes, so text retains its aspect on wide or tall canvases.
        let unit = min(size.x, size.y * 1.10) / 960
        func drawType(_ texture: MTLTexture, at y: Float) {
            ink.label = SIMD4(0.08, y, Float(texture.width) * unit / size.x, Float(texture.height) * unit / size.y)
            uniforms()
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let top: Float = 0.77
        if let label { drawType(label, at: top) }
        if let text {
            let belowLabel = label.map { Float($0.height) * unit / size.y + 0.008 } ?? 0
            drawType(text, at: top + belowLabel)
        }
    }
}
