import CoreGraphics
import CoreText
import Foundation
import Metal

/// Cached per visible item. Geometry stays in normalized coordinates across rotations.
@MainActor
final class TransitArtwork {
    struct Strokes {
        let buffer: MTLBuffer
        let count: Int
    }

    let item: ZoomScrollerItem
    let seed: Float
    private(set) var curves: Strokes?
    private(set) var squiggles: Strokes?
    private(set) var label: MTLTexture?
    private(set) var text: MTLTexture?
    private var prepared: ZoomScrollerOverlays = []

    init(_ item: ZoomScrollerItem) {
        self.item = item
        // Swift's Hasher is process-randomized. Film marks should survive a relaunch.
        let hash = item.id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        seed = Float(hash % 4093)
    }

    func prepare(_ requested: ZoomScrollerOverlays, device: MTLDevice) throws {
        let missing = requested.subtracting(prepared)
        if missing.contains(.curves) { curves = try mesh(.curve, device: device) }
        if missing.contains(.squiggles) { squiggles = try mesh(.squiggle, device: device) }
        if missing.contains(.labels), let title = item.label, !title.isEmpty {
            label = try Self.glyphs([title], isLabel: true, device: device)
        }
        if missing.contains(.text), !item.text.isEmpty {
            text = try Self.glyphs(Array(item.text.prefix(3)), isLabel: false, device: device)
        }
        prepared.formUnion(missing)
    }

    private func mesh(_ kind: ZoomScrollerStroke.Kind, device: MTLDevice) throws -> Strokes? {
        // The vertex shader evaluates each cubic from just four control points.
        // Curves of a given kind share one instanced triangle-strip draw.
        var controls: [SIMD4<Float>] = []
        for path in item.strokes where path.kind == kind {
            let a = SIMD4(path.start.x, path.start.y, path.control1.x, path.control1.y)
            let b = SIMD4(path.control2.x, path.control2.y, path.end.x, path.end.y)
            guard a.x.isFinite, a.y.isFinite, a.z.isFinite, a.w.isFinite,
                b.x.isFinite, b.y.isFinite, b.z.isFinite, b.w.isFinite
            else { continue }
            controls.append(a)
            controls.append(b)
        }
        guard !controls.isEmpty else { return nil }
        let buffer = controls.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        guard let buffer else { throw TransitRenderError.allocation }
        return Strokes(buffer: buffer, count: controls.count / 2)
    }

    /// Coverage only. One small R8 texture survives for the lifetime of this item in the cache.
    /// The source canvas is 960 units wide; labels fit on one line and body copy on three.
    private static func glyphs(_ strings: [String], isLabel: Bool, device: MTLDevice) throws -> MTLTexture? {
        let font =
            CTFontCreateUIFontForLanguage(
                isLabel ? .emphasizedSystem : .system,
                isLabel ? 49 : 27, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, isLabel ? 49 : 27, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let maxWidth: CGFloat = 800
        func line(_ value: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        }
        let ellipsis = line("…")
        let lines = strings.map { value -> CTLine in
            let full = line(value)
            guard CTLineGetTypographicBounds(full, nil, nil, nil) > maxWidth else { return full }
            return CTLineCreateTruncatedLine(full, Double(maxWidth), .end, ellipsis) ?? ellipsis
        }
        let advance = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + 3)
        let lineWidth = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0
        guard lineWidth > 0 else { return nil }
        let width = Int(ceil(min(lineWidth, maxWidth))) + 10
        let height = Int(advance) * lines.count + 6
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            throw TransitRenderError.allocation
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAllowsFontSubpixelQuantization(false)
        context.setAllowsFontSmoothing(false)
        context.setFillColor(gray: 1, alpha: 1)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(
                x: 4, y: CGFloat(height) - 3 - CTFontGetAscent(font) - CGFloat(index) * advance)
            CTLineDraw(line, context)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc), let data = context.data else {
            throw TransitRenderError.allocation
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: context.bytesPerRow)
        return texture
    }
}
