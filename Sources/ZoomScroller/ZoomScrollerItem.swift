import Foundation

/// Both sources use local file URLs. Videos play silently and loop while visible.
public enum ZoomScrollerMedia: Hashable, Sendable {
    case photo(URL)
    case video(URL)

    var url: URL {
        switch self {
        case .photo(let url), .video(let url): return url
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

/// One stop on the zoom path. Use a stable, unique ID for each item.
public struct ZoomScrollerItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let media: ZoomScrollerMedia
    public var label: String?
    public var text: [String]
    public var strokes: [ZoomScrollerStroke]

    public init(id: String, media: ZoomScrollerMedia, label: String? = nil,
                text: [String] = [], strokes: [ZoomScrollerStroke] = ZoomScrollerStroke.editorial) {
        self.id = id
        self.media = media
        self.label = label
        self.text = text
        self.strokes = strokes
    }
}

/// One cubic on a depth plane. Coordinates are normalized to the canvas at rest,
/// with (0, 0) at the upper left. Control points may extend outside the canvas.
public struct ZoomScrollerStroke: Equatable, Sendable {
    public enum Kind: Sendable { case curve, squiggle }
    public let start, control1, control2, end: SIMD2<Float>
    public let kind: Kind

    public init(start: SIMD2<Float>, control1: SIMD2<Float>, control2: SIMD2<Float>,
                end: SIMD2<Float>, kind: Kind = .curve) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
        self.kind = kind
    }

    public static let editorial: [Self] = [
        .init(start: [-0.14, 0.84], control1: [0.12, 0.67], control2: [0.42, 0.86], end: [0.48, 1.08]),
        .init(start: [1.08, 0.04], control1: [0.58, 0.29], control2: [1.23, -0.02],
              end: [1.04, 0.32], kind: .squiggle)
    ]
}

public struct ZoomScrollerOverlays: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let curves = Self(rawValue: 1 << 0)
    public static let squiggles = Self(rawValue: 1 << 1)
    public static let text = Self(rawValue: 1 << 2)
    public static let labels = Self(rawValue: 1 << 3)
    public static let dust = Self(rawValue: 1 << 4)
    public static let dirt = Self(rawValue: 1 << 5)
    public static let all: Self = [.curves, .squiggles, .text, .labels, .dust, .dirt]
}

public struct ZoomScrollerStyle: Equatable, Sendable {
    public var overlays: ZoomScrollerOverlays
    public let distortion: Float
    public let shutter: Float

    /// Distortion and shutter are normalized strengths. Zero disables the effect.
    public init(overlays: ZoomScrollerOverlays = .all, distortion: Float = 1, shutter: Float = 1) {
        self.overlays = overlays
        self.distortion = distortion.isFinite ? min(1, max(0, distortion)) : 1
        self.shutter = shutter.isFinite ? min(1, max(0, shutter)) : 1
    }
}
