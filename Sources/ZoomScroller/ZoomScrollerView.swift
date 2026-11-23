import SwiftUI
import MetalKit

/// A pinch-navigable surface for a sequence of local photos and silent looping videos.
public struct ZoomScrollerView: View {
    public var items: [ZoomScrollerItem]
    @Binding private var selection: Int
    public var style: ZoomScrollerStyle
    /// Drag up or down with one finger to scrub and release to settle, just like a pinch.
    public var allowsVerticalSwipes: Bool
    private let onFailure: ((URL, Error) -> Void)?
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The binding receives settled indices. Write to it to navigate programmatically.
    public init(items: [ZoomScrollerItem], selection: Binding<Int>, style: ZoomScrollerStyle = .init(),
                allowsVerticalSwipes: Bool = false, onFailure: ((URL, Error) -> Void)? = nil) {
        self.items = items
        _selection = selection
        self.style = style
        self.allowsVerticalSwipes = allowsVerticalSwipes
        self.onFailure = onFailure
    }

    public var body: some View {
        TransitHost(items: items, selection: $selection, style: style, active: phase == .active,
                    reduceMotion: reduceMotion, progress: nil, allowsVerticalSwipes: allowsVerticalSwipes, onFailure: onFailure)
    }
}

/// Drive a single transition with a slider, scroll position, or your own clock.
public struct ZoomScrollerTransition: View {
    public let from, to: ZoomScrollerItem
    public var progress: Double
    public var style: ZoomScrollerStyle
    private let onFailure: ((URL, Error) -> Void)?
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(from: ZoomScrollerItem, to: ZoomScrollerItem, progress: Double, style: ZoomScrollerStyle = .init(),
                onFailure: ((URL, Error) -> Void)? = nil) {
        self.from = from
        self.to = to
        self.progress = progress
        self.style = style
        self.onFailure = onFailure
    }

    public var body: some View {
        TransitHost(items: [from, to], selection: .constant(progress >= 0.5 ? 1 : 0),
                    style: style, active: phase == .active, reduceMotion: reduceMotion,
                    progress: progress.isFinite ? min(1, max(0, progress)) : 0, allowsVerticalSwipes: false, onFailure: onFailure)
    }
}

private struct TransitHost: UIViewRepresentable {
    let items: [ZoomScrollerItem]
    @Binding var selection: Int
    let style: ZoomScrollerStyle
    let active, reduceMotion: Bool
    let progress: Double?
    let allowsVerticalSwipes: Bool
    let onFailure: ((URL, Error) -> Void)?

    func makeUIView(context: Context) -> TransitSurface { TransitSurface() }

    func updateUIView(_ view: TransitSurface, context: Context) {
        view.onSelection = { [binding = $selection] in binding.wrappedValue = $0 }
        view.onFailure = onFailure
        view.allowsVerticalSwipes = allowsVerticalSwipes
        view.configure(items: items, selection: selection, style: style,
                       active: active, reduceMotion: reduceMotion, progress: progress)
    }

    static func dismantleUIView(_ view: TransitSurface, coordinator: ()) { view.shutDown() }
}
