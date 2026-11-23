import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import ZoomScroller

final class MediaWindowTests: XCTestCase {
    func testPortraitTrackMapsUprightCornersBackToEncodedPixels() throws {
        // Both these transforms store a portrait frame in a landscape video track.
        let clockwise = try ClipGeometry(size: CGSize(width: 640, height: 360),
                                          preferred: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0))
        let counterclockwise = try ClipGeometry(size: CGSize(width: 640, height: 360),
                                                 preferred: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 640))
        XCTAssertEqual(clockwise.aspect, 360.0 / 640.0, accuracy: 0.0001)
        XCTAssertEqual(CGPoint.zero.applying(clockwise.uvTransform), CGPoint(x: 0, y: 1))
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(clockwise.uvTransform), CGPoint(x: 1, y: 0))
        XCTAssertEqual(CGPoint.zero.applying(counterclockwise.uvTransform), CGPoint(x: 1, y: 0))
        XCTAssertThrowsError(try ClipGeometry(size: .zero, preferred: .identity))
    }

    @MainActor
    func testJumpEvictsStaleRequestsAndSharesOneUprightMipmappedPhoto() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try MediaWindow(device: device)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("portrait.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL,
                                                                         UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let items = (0..<7).map { index in
            ZoomScrollerItem(id: String(index), media: .photo(index < 3 ? directory.appendingPathComponent("\(index)") : photo))
        }
        let loaded = expectation(description: "shared photo decoded")
        var changes = 0
        window.onChange = { changes += 1; loaded.fulfill() }
        window.onFailure = { url, error in XCTFail("Unexpected load failure for \(url): \(error)") }
        window.prepare(items: items, around: 0)
        window.prepare(items: items, around: 4)
        await fulfillment(of: [loaded], timeout: 8)

        let frame = try XCTUnwrap(window.frame(for: .photo(photo), at: 0))
        XCTAssertEqual(frame.texture.width, 8)
        XCTAssertEqual(frame.texture.height, 16)
        XCTAssertEqual(frame.uvTransform, .identity)
        XCTAssertGreaterThan(frame.texture.mipmapLevelCount, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(window.frame(for: items[0].media, at: 0))
        window.removeAll()
        XCTAssertNil(window.frame(for: .photo(photo), at: 0))
    }
}
