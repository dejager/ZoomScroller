import UIKit
import QuartzCore
@preconcurrency import MetalKit

@MainActor
final class TransitSurface: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    var onSelection: ((Int) -> Void)?
    var onFailure: ((URL, Error) -> Void)?

    private var renderer: TransitRenderer?
    private var media: MediaWindow?
    private var items: [ZoomScrollerItem] = []
    private var style = ZoomScrollerStyle()
    private var playhead = TransitPlayhead()
    private var selection = 0
    private var active = false
    private var reduceMotion = false
    private var externalProgress: Double?
    private var preparedIndex: Int?
    private var preparedOverlays: ZoomScrollerOverlays?
    private var playing = Set<ZoomScrollerMedia>()
    private var playbackIndices: ClosedRange<Int>?
    private var failures = Set<URL>()
    private var lastTick: CFTimeInterval?
    private var needsFrame = true
    private var lastVideoTexture: MTLTexture?
    private var rendererError: Error?

    // Covers the previous drawable while an entirely new feed or a failed item is shown.
    private let status = UILabel()
    private lazy var pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(scrub(_:)))
    private lazy var dragRecognizer: UIPanGestureRecognizer = {
        let drag = UIPanGestureRecognizer(target: self, action: #selector(scrub(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        drag.isEnabled = false
        return drag
    }()
    private weak var activeGesture: UIGestureRecognizer?

    var allowsVerticalSwipes = false {
        didSet {
            guard allowsVerticalSwipes != oldValue else { return }
            updateGestureAvailability()
        }
    }

    private func updateGestureAvailability() {
        let interactive = externalProgress == nil
        pinchRecognizer.isEnabled = interactive
        dragRecognizer.isEnabled = interactive && allowsVerticalSwipes
        accessibilityTraits = interactive ? [.image, .adjustable] : [.image]
        accessibilityHint = interactive ? (allowsVerticalSwipes
            ? "Drag up or spread two fingers to advance. Drag down or pinch to go back."
            : "Spread two fingers to advance, or pinch to go back.") : nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dragRecognizer {
            let velocity = dragRecognizer.velocity(in: self)
            return activeGesture !== pinchRecognizer && abs(velocity.y) > abs(velocity.x)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === dragRecognizer && other === pinchRecognizer
    }

    init() {
        let gpu = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: gpu)
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm_srgb
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0.025, 0.025, 0.025, 1)
        backgroundColor = .black
        preferredFramesPerSecond = 60

        status.backgroundColor = .black
        status.textColor = .secondaryLabel
        status.overrideUserInterfaceStyle = .dark
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textAlignment = .center
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        status.frame = bounds
        addSubview(status)
        isAccessibilityElement = true
        addGestureRecognizer(pinchRecognizer)
        addGestureRecognizer(dragRecognizer)
        updateGestureAvailability()

        if let gpu {
            do {
                renderer = try TransitRenderer(device: gpu)
                media = try MediaWindow(device: gpu)
            } catch { rendererError = error }
        }
        media?.onChange = { [weak self] in self?.invalidateFrame() }
        media?.onFailure = { [weak self] url, error in
            guard let self else { return }
            failures.insert(url)
            onFailure?(url, error)
            invalidateFrame()
        }
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init()") }

    func configure(items newItems: [ZoomScrollerItem], selection requested: Int, style: ZoomScrollerStyle,
                   active: Bool, reduceMotion: Bool, progress: Double?) {
        let contentChanged = items != newItems
        let presentationChanged = self.style != style || self.reduceMotion != reduceMotion
        let activityChanged = self.active != active
        let progressChanged = externalProgress != progress
        let interactionChanged = (externalProgress == nil) != (progress == nil)
        externalProgress = progress
        if interactionChanged { updateGestureAvailability() }
        self.active = active
        self.reduceMotion = reduceMotion
        self.style = style
        let oldSelection = selection
        if contentChanged {
            // Editing a caption or a stroke during a pinch should preserve the playhead.
            let sameOrder = items.count == newItems.count && zip(items, newItems).allSatisfy { $0.id == $1.id }
            items = newItems
            if !sameOrder { playhead.reset(count: items.count, selection: requested) }
            preparedIndex = nil
        }
        if contentChanged || presentationChanged || activityChanged { playbackIndices = nil }
        selection = playhead.clamped(requested)
        if let progress {
            playhead.seek(to: reduceMotion ? progress.rounded() : progress)
        } else if selection != oldSelection {
            playhead.navigate(to: selection, animated: !reduceMotion)
        }
        if requested != selection {
            // SwiftUI is currently updating this representable. Publish normalization
            // after the transaction and ignore it if an intervening update won.
            let normalized = selection
            DispatchQueue.main.async { [weak self] in
                guard let self, selection == normalized else { return }
                onSelection?(normalized)
            }
        }
        if contentChanged || selection != oldSelection || presentationChanged || activityChanged || progressChanged {
            updateAccessibility()
            invalidateFrame()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        invalidateFrame()
    }

    func shutDown() {
        active = false
        isPaused = true
        delegate = nil
        media?.onChange = nil
        media?.onFailure = nil
        media?.removeAll()
        onFailure = nil
        onSelection = nil
        lastVideoTexture = nil
    }

    private func updateAccessibility() {
        guard items.indices.contains(selection) else {
            accessibilityLabel = "Empty feed"
            accessibilityValue = nil
            return
        }
        accessibilityLabel = items[selection].label ?? "Media"
        accessibilityValue = "\(selection + 1) of \(items.count)"
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ delta: Int) {
        guard externalProgress == nil, !items.isEmpty else { return }
        selection = playhead.clamped(selection + delta)
        playhead.navigate(to: selection, animated: !reduceMotion)
        updateAccessibility()
        onSelection?(selection)
        invalidateFrame()
    }

    @objc private func scrub(_ gesture: UIGestureRecognizer) {
        guard !items.isEmpty, externalProgress == nil else { return }
        if gesture.state == .began {
            // A second finger can take over a running drag without resetting the camera.
            guard gesture === pinchRecognizer || activeGesture !== pinchRecognizer else { return }
            activeGesture = gesture
            playhead.beginTracking(input: gesture === dragRecognizer ? .verticalDrag : .pinch)
        }
        guard activeGesture === gesture else { return }
        let now = CACurrentMediaTime()
        switch gesture.state {
        case .began, .changed, .ended:
            if gesture === pinchRecognizer {
                playhead.track(scale: pinchRecognizer.scale, time: now)
            } else {
                let dy = dragRecognizer.translation(in: self).y
                playhead.track(verticalDelta: dy, viewportHeight: bounds.height, time: now,
                               panSpeed: dragRecognizer.velocity(in: self).y)
                dragRecognizer.setTranslation(.zero, in: self)
            }
            if gesture.state == .ended {
                playhead.endTracking(cancelled: false)
                activeGesture = nil
            }
        case .cancelled, .failed:
            playhead.endTracking(cancelled: true)
            activeGesture = nil
        default: return
        }
        invalidateFrame()
    }

    private func invalidateFrame() {
        needsFrame = true
        guard active, window != nil else {
            updatePlayback([])
            playbackIndices = nil
            schedule(continuous: false)
            return
        }
        if items.isEmpty {
            media?.removeAll()
            preparedIndex = nil
            preparedOverlays = nil
            failures.removeAll()
            updatePlayback([])
            lastVideoTexture = nil
            showStatus(nil)
            schedule(continuous: false)
            return
        }
        if renderer == nil || media == nil || rendererError != nil {
            showStatus(rendererError?.localizedDescription ?? "Metal is unavailable on this device.")
            schedule(continuous: false)
            return
        }
        if isPaused { setNeedsDisplay() }
    }

    private func schedule(continuous: Bool) {
        let shouldPause = !continuous
        if isPaused != shouldPause {
            enableSetNeedsDisplay = shouldPause
            isPaused = shouldPause
        }
        if shouldPause { lastTick = nil }
    }

    private func updatePlayback(_ next: Set<ZoomScrollerMedia>) {
        guard playing != next else { return }
        playing = next
        media?.setPlaying(next)
    }

    private func showStatus(_ message: String?) {
        status.text = message
        status.isHidden = false
    }

    private func failRendering(_ error: Error) {
        rendererError = error
        updatePlayback([])
        showStatus(error.localizedDescription)
        schedule(continuous: false)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidateFrame() }

    func draw(in view: MTKView) {
        guard active, window != nil, bounds.width > 0, bounds.height > 0,
              rendererError == nil, let renderer, let media else { return }
        let now = CACurrentMediaTime()
        let dt = lastTick.map { min(0.1, max(0, now - $0)) } ?? 1.0 / 60
        lastTick = now
        if let settled = playhead.advance(by: dt, reduceMotion: reduceMotion) {
            needsFrame = true
            if settled != selection {
                selection = settled
                updateAccessibility()
                onSelection?(settled)
            }
        }
        guard let span = playhead.span else { return }
        if preparedIndex != span.lower || preparedOverlays != style.overlays {
            let moved = preparedIndex != span.lower
            preparedIndex = span.lower
            preparedOverlays = style.overlays
            let neighbors = max(0, span.lower - 1)...min(items.count - 1, span.lower + 2)
            if moved {
                failures.formIntersection(neighbors.map { items[$0].media.url })
                media.prepare(items: items, around: span.lower)
            }
            do {
                try renderer.prepare(items: items[neighbors], overlays: style.overlays)
            } catch {
                failRendering(error)
                return
            }
        }
        let a = items[span.lower], b = items[span.upper]
        let isPair = span.lower != span.upper
        let indices = span.lower...span.upper
        if playbackIndices != indices {
            var videos = Set<ZoomScrollerMedia>()
            if !reduceMotion {
                if a.media.isVideo { videos.insert(a.media) }
                if isPair && b.media.isVideo { videos.insert(b.media) }
            }
            updatePlayback(videos)
            playbackIndices = indices
        }
        let first = media.frame(for: a.media, at: now)
        let second = isPair ? media.frame(for: b.media, at: now) : first
        if let left = first ?? second, let right = second ?? first {
            // A held video often returns the same decoded frame across display ticks.
            if needsFrame || isPair || playhead.isMoving || lastVideoTexture !== left.texture {
                do {
                    let submitted = try renderer.draw(in: self, from: first == nil ? b : a,
                                                      to: second == nil ? a : b,
                                                      progress: first == nil || second == nil ? 0 : span.progress,
                                                      edgeStretch: span.edgeStretch, edgeLensGain: playhead.edgeLensGain,
                                                      first: left, second: right, style: style)
                    guard submitted else {
                        needsFrame = true
                        schedule(continuous: true)
                        return
                    }
                    status.isHidden = true
                    lastVideoTexture = isPair ? nil : left.texture
                    needsFrame = false
                } catch {
                    failRendering(error)
                    return
                }
            }
        } else {
            let url = (span.progress < 0.5 ? a : b).media.url
            showStatus(failures.contains(url) ? "This item couldn’t be opened." : nil)
            lastVideoTexture = nil
        }
        let liveVideo = playing.contains { !failures.contains($0.url) }
        schedule(continuous: (playhead.isMoving && !(reduceMotion && playhead.isTracking)) || liveVideo)
    }
}
