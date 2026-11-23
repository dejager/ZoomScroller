import AVFoundation
import CoreVideo
import Metal

private final class NotificationObservers {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

struct ClipGeometry {
    let aspect: Float
    let uvTransform: CGAffineTransform

    init(size: CGSize, preferred: CGAffineTransform) throws {
        let display = CGRect(origin: .zero, size: size).applying(preferred).standardized
        let determinant = preferred.a * preferred.d - preferred.b * preferred.c
        guard size.width > 0, size.height > 0, display.width.isFinite, display.height.isFinite,
              display.width > 0, display.height > 0, determinant.isFinite, abs(determinant) > 0.000001 else {
            throw MediaError.invalidDimensions
        }
        aspect = Float(display.width / display.height)
        uvTransform = CGAffineTransform(scaleX: display.width, y: display.height)
            .concatenating(CGAffineTransform(translationX: display.minX, y: display.minY))
            .concatenating(preferred.inverted())
            .concatenating(CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height))
    }
}

@MainActor
final class VideoClip {
    private let item: AVPlayerItem
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let geometry: ClipGeometry
    private let cache: CVMetalTextureCache
    private var status: NSKeyValueObservation?
    private let notifications = NotificationObservers()
    private var playing = false
    private var failed = false
    private var lastFrame: TransitFrame?
    private let onReady: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(asset: AVURLAsset, geometry: ClipGeometry, cache: CVMetalTextureCache,
         onReady: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) {
        self.geometry = geometry
        self.cache = cache
        self.onReady = onReady
        self.onFailure = onFailure
        output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: false,
            // Match the sRGB poster and Metal texture view. Untagged BGRA
            // alone can carry Rec. 709 transfer values with different midtones.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        output.suppressesPlayerRendering = true
        item = AVPlayerItem(asset: asset)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.item.status {
                case .failed: self.fail(self.item.error ?? MediaError.missingVideo)
                case .readyToPlay: self.onReady()
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        notifications.add(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.playing { self.player.play() }
            }
        })
        notifications.add(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                                object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in self?.fail(error ?? MediaError.missingVideo) }
        })
    }

    func setPlaying(_ value: Bool) {
        guard !failed, value != playing else { return }
        playing = value
        if value { player.play() } else { player.pause() }
    }

    func frame(at hostTime: CFTimeInterval) -> TransitFrame? {
        guard !failed, item.status == .readyToPlay else { return lastFrame }
        let time = output.itemTime(forHostTime: hostTime)
        guard time.isValid, output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return lastFrame
        }
        var backing: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm_srgb, CVPixelBufferGetWidth(buffer),
            CVPixelBufferGetHeight(buffer), 0, &backing)
        guard result == kCVReturnSuccess, let backing, let texture = CVMetalTextureGetTexture(backing) else {
            fail(MediaError.textureUnavailable)
            return lastFrame
        }
        let frame = TransitFrame(texture: texture, aspect: geometry.aspect, uvTransform: geometry.uvTransform,
                                 backing: backing, pixelBuffer: buffer)
        lastFrame = frame
        return frame
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        player.pause()
        onFailure(error)
    }
}
