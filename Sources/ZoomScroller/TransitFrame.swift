import CoreVideo
import ImageIO
import Metal

/// Immutable. Holding a frame through GPU completion also holds its decoder surface.
struct TransitFrame: @unchecked Sendable {
    let texture: MTLTexture
    let aspect: Float
    let uvTransform: CGAffineTransform
    private let backing: CVMetalTexture?
    private let pixelBuffer: CVPixelBuffer?

    init(texture: MTLTexture, aspect: Float, uvTransform: CGAffineTransform = .identity,
         backing: CVMetalTexture? = nil, pixelBuffer: CVPixelBuffer? = nil) {
        self.texture = texture
        self.aspect = aspect
        self.uvTransform = uvTransform
        self.backing = backing
        self.pixelBuffer = pixelBuffer
    }
}

enum MediaError: LocalizedError {
    case localFileRequired, unreadablePhoto, missingVideo, invalidDimensions, textureUnavailable

    var errorDescription: String? {
        switch self {
        case .localFileRequired: return "The media source must be a local file URL."
        case .unreadablePhoto: return "Image I/O could not decode the photograph."
        case .missingVideo: return "The file contains no playable video track."
        case .invalidDimensions: return "The media has invalid display dimensions."
        case .textureUnavailable: return "Metal could not prepare a media texture."
        }
    }
}

/// One serial, off-main decode lane bounds temporary bitmap and staging-buffer memory.
actor StillDecoder {
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw MediaError.textureUnavailable }
        self.device = device
        self.queue = queue
    }

    func photo(at url: URL) throws -> TransitFrame {
        try Task.checkCancellation()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw MediaError.unreadablePhoto
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaError.unreadablePhoto
        }
        return try upload(image)
    }

    func upload(_ image: CGImage) throws -> TransitFrame {
        try Task.checkCancellation()
        let width = image.width
        let height = image.height
        let rowBytes = (width * 4 + 255) & ~255
        // Drawing into an sRGB context converts embedded ICC profiles before the GPU
        // interprets these bytes as sRGB. Image I/O already applied EXIF orientation.
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let staging = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let context = CGContext(data: staging.contents(), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                      bitmapInfo: bitmap) else { throw MediaError.textureUnavailable }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        try Task.checkCancellation()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { throw MediaError.textureUnavailable }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                  sourceBytesPerImage: rowBytes * height, sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        if texture.mipmapLevelCount > 1 { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        command.commit()
        // This queue is private to the decode actor. Publish only a fully usable texture.
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return TransitFrame(texture: texture, aspect: Float(width) / Float(height))
    }
}
