import XCTest

final class FeedTests: XCTestCase {
    func testPinchAcrossPlayingFilmAndBack() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.descendants(matching: .any).matching(identifier: "feedCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.pinch(withScale: 2.0, velocity: 0.65)
        assertPosition("2 of 5", on: canvas)

        let first = try sample(canvas)
        let frameChanged = NSPredicate { _, _ in
            guard let later = try? self.sample(canvas) else { return false }
            return zip(first, later).filter { abs(Int($0.0) - Int($0.1)) > 5 }.count > 80
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: frameChanged, object: nil)], timeout: 6), .completed)
        canvas.pinch(withScale: 0.5, velocity: -0.65)
        assertPosition("1 of 5", on: canvas)
    }

    private func assertPosition(_ value: String, on canvas: XCUIElement,
                                file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 6), .completed, file: file, line: line)
    }

    private func sample(_ canvas: XCUIElement) throws -> [UInt8] {
        let image = try XCTUnwrap(canvas.screenshot().image.cgImage)
        let side = 48
        var pixels = Array(repeating: UInt8.zero, count: side * side)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: side, height: side,
                                                  bitsPerComponent: 8, bytesPerRow: side,
                                                  space: CGColorSpaceCreateDeviceGray(),
                                                  bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    func testSwipeBrowseWithoutCaptionsOrEffectsControls() {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.descendants(matching: .any)["feedCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        assertPosition("1 of 5", on: canvas)
        XCTAssertEqual(app.staticTexts.count, 0)
        XCTAssertTrue(app.buttons["Share post"].exists)
        let low = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.43, dy: 0.70))
        let high = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.43, dy: 0.32))
        low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 1)
        assertPosition("2 of 5", on: canvas)
        XCTAssertEqual(app.staticTexts.count, 0)

        XCTAssertFalse(app.buttons["Transition effects"].exists)

        let flickEnd = high.withOffset(CGVector(dx: 0, dy: 60))
        high.press(forDuration: 0.05, thenDragTo: flickEnd, withVelocity: .fast, thenHoldForDuration: 0)
        assertPosition("1 of 5", on: canvas)
        flickEnd.press(forDuration: 0.05, thenDragTo: high, withVelocity: .fast, thenHoldForDuration: 0)
        assertPosition("2 of 5", on: canvas)
    }

    func testPullBeyondBothEndsAndNavigateBack() {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.descendants(matching: .any)["feedCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let top = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.24))
        let bottom = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.76))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.5)
        assertPosition("1 of 5", on: canvas)
        canvas.pinch(withScale: 0.55, velocity: -0.65)
        assertPosition("1 of 5", on: canvas)
        for shot in 2...5 {
            bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0)
            assertPosition("\(shot) of 5", on: canvas)
        }
        XCTAssertEqual(canvas.label, "Forest boardwalk")
        bottom.press(forDuration: 0.1, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.65)
        assertPosition("5 of 5", on: canvas)
        canvas.pinch(withScale: 1.8, velocity: 0.65)
        assertPosition("5 of 5", on: canvas)
        canvas.pinch(withScale: 0.5, velocity: -0.9)
        assertPosition("4 of 5", on: canvas)
    }
}
