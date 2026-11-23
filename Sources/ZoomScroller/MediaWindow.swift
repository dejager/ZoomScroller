import AVFoundation
import Metal

/// Starting and cancelling a request share an isolation domain. AVFoundation
/// decodes asynchronously and its completion only delivers the immutable image.
@MainActor
private final class PosterRequest {
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
    }

    func image() async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        } onCancel: {
            Task { @MainActor in self.generator.cancelAllCGImageGeneration() }
        }
    }
}

@MainActor
final class MediaWindow {
    private final class Entry {
        var task: Task<Void, Never>?
        var still: TransitFrame?
        var clip: VideoClip?

        deinit { task?.cancel() }
    }

    var onChange: (() -> Void)?
    var onFailure: ((URL, Error) -> Void)?

    private let decoder: StillDecoder
    private let textureCache: CVMetalTextureCache
    private var entries: [ZoomScrollerMedia: Entry] = [:]
    private var playing: Set<ZoomScrollerMedia> = []

    init(device: MTLDevice) throws {
        decoder = try StillDecoder(device: device)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MediaError.textureUnavailable }
        textureCache = cache
    }

    func prepare(items: [ZoomScrollerItem], around index: Int) {
        guard items.indices.contains(index) else {
            removeAll()
            return
        }
        // Prioritize the visible pair. Duplicate URLs share a single decoder.
        let desired = [index, index + 1, index - 1, index + 2]
            .filter(items.indices.contains)
            .map { items[$0].media }
        let outgoing = entries.keys.filter { !desired.contains($0) }
        for media in outgoing { discard(media) }
        for media in desired where entries[media] == nil { load(media) }
    }

    func frame(for media: ZoomScrollerMedia, at hostTime: CFTimeInterval) -> TransitFrame? {
        guard let entry = entries[media] else { return nil }
        if let frame = entry.clip?.frame(at: hostTime) {
            entry.still = nil
            return frame
        }
        return entry.still
    }

    func setPlaying(_ media: Set<ZoomScrollerMedia>) {
        guard playing != media else { return }
        playing = media
        for (key, entry) in entries { entry.clip?.setPlaying(playing.contains(key)) }
    }

    func removeAll() {
        for key in Array(entries.keys) { discard(key) }
        playing.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func discard(_ media: ZoomScrollerMedia) {
        guard let entry = entries.removeValue(forKey: media) else { return }
        entry.task?.cancel()
        entry.clip?.setPlaying(false)
    }

    private func load(_ media: ZoomScrollerMedia) {
        let entry = Entry()
        entries[media] = entry
        entry.task = Task { [weak self, weak entry, decoder, textureCache] in
            do {
                try Task.checkCancellation()
                guard media.url.isFileURL else { throw MediaError.localFileRequired }
                switch media {
                case .photo(let url):
                    let frame = try await decoder.photo(at: url)
                    try Task.checkCancellation()
                    entry?.still = frame
                    self?.onChange?()
                case .video(let url):
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw MediaError.missingVideo
                    }
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let geometry = try ClipGeometry(size: size, preferred: transform)
                    try Task.checkCancellation()
                    let clip = VideoClip(asset: asset, geometry: geometry, cache: textureCache,
                                         onReady: { [weak self, weak entry] in
                                             guard entry != nil else { return }
                                             self?.onChange?()
                                         }, onFailure: { [weak self, weak entry] error in
                                             guard entry != nil else { return }
                                             self?.onFailure?(url, error)
                                         })
                    entry?.clip = clip
                    clip.setPlaying(self?.playing.contains(media) == true)
                    // Paused neighbors can be drawn before playback delivers a CVPixelBuffer.
                    if let poster = await PosterRequest(asset: asset).image() {
                        try Task.checkCancellation()
                        let frame = try await decoder.upload(poster)
                        try Task.checkCancellation()
                        entry?.still = frame
                        self?.onChange?()
                    }
                }
            } catch {
                guard !Task.isCancelled, entry != nil else { return }
                self?.onFailure?(media.url, error)
            }
        }
    }
}
