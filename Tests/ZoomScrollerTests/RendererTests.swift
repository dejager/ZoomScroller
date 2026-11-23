import Metal
import XCTest

@testable import ZoomScroller

final class RendererTests: XCTestCase {
    @MainActor
    func testEndpointsAndReverseSamplingMatchPixelForPixel() throws {
        let h = try Harness()
        let style = ZoomScrollerStyle()
        let final = try h.render(1, style: style)
        XCTAssertEqual(final, try h.render(0, style: style, swapped: true))
        let forward = try h.render(0.43, style: style)
        XCTAssertNotEqual(forward, final)
        _ = try h.render(0.84, style: style)
        XCTAssertEqual(forward, try h.render(0.43, style: style))
        XCTAssertNotEqual(forward, try h.render(0.43, style: .init(shutter: 0)))
        XCTAssertNotEqual(forward, try h.render(0.43, style: .init(distortion: 0)))
    }

    @MainActor
    func testEdgesRenderTheSameCameraAsTheTransitionWithLowerExposure() throws {
        let h = try Harness()
        let clean = ZoomScrollerStyle(overlays: [])
        let linear = (0...255).map { byte -> Double in
            let s = Double(byte) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        for (offset, gain): (Float, Float) in [(-0.18, 1), (0.18, 1), (-0.14, 1.24), (0.14, 1.24)] {
            // At these phases the entire ordinary shutter is still on one shot.
            let travel = offset * gain
            let reference = try h.render(offset < 0 ? 1 + travel : travel, style: clean, swapped: offset < 0)
            let pulled = try h.render(0, style: clean, edgeStretch: offset, edgeLensGain: gain)
            let brightness = exp2(-1.6 * Double(abs(offset)))
            var maxError = 0.0
            for i in reference.indices where i % 4 != 3 {
                let expected = linear[Int(reference[i])] * brightness
                maxError = max(maxError, abs(linear[Int(pulled[i])] - expected))
            }
            XCTAssertLessThan(maxError, 0.01)
            XCTAssertNotEqual(pulled, reference)
            XCTAssertNotEqual(pulled, try h.render(0, style: .init(overlays: [], shutter: 0),
                                                   edgeStretch: offset, edgeLensGain: gain))
            XCTAssertNotEqual(pulled, try h.render(0, style: .init(overlays: [], distortion: 0),
                                                   edgeStretch: offset, edgeLensGain: gain))
            // A neighbor must never contribute, even at the limit of a pull.
            let limit: Float = offset < 0 ? -0.28 : 0.28
            XCTAssertEqual(try h.render(0, style: .init(), edgeStretch: limit, edgeLensGain: gain),
                           try h.render(0, style: .init(), edgeStretch: limit, edgeLensGain: gain, repeatFirst: true))
        }
        XCTAssertEqual(try h.render(0, style: clean), h.inputBytes)
    }

    @MainActor
    func testUnadornedHoldAndIndependentLayers() throws {
        let h = try Harness()
        let clean = try h.render(0, style: .init(overlays: []))
        XCTAssertEqual(clean, h.inputBytes, "A matched-aspect hold should reproduce the source.")
        for overlay: ZoomScrollerOverlays in [.curves, .squiggles, .text, .labels, .dust, .dirt] {
            XCTAssertNotEqual(
                clean, try h.render(0, style: .init(overlays: overlay)),
                "Overlay \(overlay.rawValue) should independently affect this scene.")
        }
        XCTAssertEqual(
            clean, try h.render(0, style: .init(overlays: [])),
            "Cached artwork must disappear as soon as its switch is turned off.")
    }

    @MainActor
    private final class Harness {
        let renderer: TransitRenderer
        let first, second: TransitFrame
        let firstItem, secondItem: ZoomScrollerItem
        let inputBytes: [UInt8]
        let queue: MTLCommandQueue
        let target: MTLTexture
        let width = 160, height = 192

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("A Metal device is required.") }
            renderer = try TransitRenderer(device: device)
            queue = try XCTUnwrap(device.makeCommandQueue())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .renderTarget]
            let a = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let b = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let n = (y * width + x) * 4
                    pixels[n] = x % 16 < 8 ? 75 : 135
                    pixels[n + 1] = UInt8(y)
                    pixels[n + 2] = UInt8(10 + x)
                }
            }
            inputBytes = pixels
            let region = MTLRegionMake2D(0, 0, width, height)
            a.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
            for n in stride(from: 0, to: pixels.count, by: 4) { pixels[n + 1] = 255 - pixels[n + 1] }
            b.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
            first = TransitFrame(texture: a, aspect: Float(width) / Float(height))
            second = TransitFrame(texture: b, aspect: Float(width) / Float(height))
            let url = URL(fileURLWithPath: "/unused")
            firstItem = ZoomScrollerItem(id: "test-a", media: .photo(url), label: "West", text: ["Lower fall"])
            secondItem = ZoomScrollerItem(id: "test-b", media: .video(url), label: "East", text: ["Upper fall"])
        }

        func render(_ progress: Float, style: ZoomScrollerStyle, swapped: Bool = false,
                    edgeStretch: Float = 0, edgeLensGain: Float = 1, repeatFirst: Bool = false) throws -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(
                pass: pass, scale: 1, command: command,
                from: swapped ? secondItem : firstItem, to: (swapped || repeatFirst) ? firstItem : secondItem,
                progress: progress, edgeStretch: edgeStretch, edgeLensGain: edgeLensGain,
                first: swapped ? second : first, second: (swapped || repeatFirst) ? first : second,
                style: style)
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }
    }
}
