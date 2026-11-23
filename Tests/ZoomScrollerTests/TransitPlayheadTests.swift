import XCTest
@testable import ZoomScroller

final class TransitPlayheadTests: XCTestCase {
    func testEndpointsAndFractionalPairs() {
        XCTAssertNil(TransitSpan(position: 0, count: 0))
        var path = TransitPlayhead()
        path.reset(count: 4, selection: 22)
        XCTAssertEqual(path.span?.lower, 3)
        XCTAssertEqual(path.span?.upper, 3)
        path.seek(to: 1.25)
        XCTAssertEqual(path.span?.lower, 1)
        XCTAssertEqual(path.span?.upper, 2)
        XCTAssertEqual(path.span?.progress, 0.25)
        path.seek(to: .nan)
        XCTAssertEqual(path.span?.lower, 0)
    }

    func testDistantJumpSkipsIntermediateStopsAndAdjacentStepSettlesOnce() {
        var path = TransitPlayhead()
        path.reset(count: 20, selection: 0)
        path.navigate(to: 15, animated: true)
        XCTAssertEqual(path.position, 15)
        XCTAssertFalse(path.isMoving)
        path.navigate(to: 16, animated: true)
        let arrivals = (0..<240).compactMap { _ in path.advance(by: 1.0 / 60, reduceMotion: false) }
        XCTAssertEqual(arrivals, [16])
    }

    func testPinchCanInterruptSettleWithoutResettingPosition() {
        var path = TransitPlayhead()
        path.reset(count: 3, selection: 0)
        path.navigate(to: 1, animated: true)
        _ = path.advance(by: 0.18, reduceMotion: false)
        let position = path.position
        path.beginTracking()
        XCTAssertEqual(path.position, position)
        path.track(scale: 1, time: 0)
        path.track(scale: 0.70, time: 0.4)
        path.endTracking(cancelled: false)
        let stops = (0..<240).compactMap { _ in path.advance(by: 1.0 / 60, reduceMotion: false) }
        XCTAssertEqual(stops, [0])
    }

    func testDragCanHoldAndChooseEitherStopFromTheSamePosition() {
        for reverse in [false, true] {
            var path = TransitPlayhead()
            path.reset(count: 3, selection: 1)
            path.beginTracking(input: .verticalDrag)
            path.track(verticalDelta: 0, viewportHeight: 800, time: 0)
            path.track(verticalDelta: reverse ? -390 : -300, viewportHeight: 800, time: 0.5)
            _ = path.advance(by: 1, reduceMotion: false)
            if reverse {
                path.track(verticalDelta: 90, viewportHeight: 800, time: 1.7)
            }
            XCTAssertNil(path.advance(by: 1, reduceMotion: false))
            XCTAssertEqual(path.position, 1.5, accuracy: 0.0001)
            XCTAssertFalse(path.isMoving)
            XCTAssertTrue(path.isTracking)
            path.track(verticalDelta: 0, viewportHeight: 800, time: 3)
            path.endTracking(cancelled: false)
            let arrivals = (0..<180).compactMap { _ in path.advance(by: 1.0 / 60, reduceMotion: false) }
            XCTAssertEqual(arrivals, [reverse ? 1 : 2])
        }
    }

    func testShortDragCommitsOnlyWithMomentumAtLift() {
        for direction in [-1.0, 1.0] {
            for (duration, pause, advances) in [(0.06, 0.0, true), (0.5, 0.0, false), (0.06, 0.4, false)] {
                var path = TransitPlayhead()
                path.reset(count: 5, selection: 2)
                path.beginTracking(input: .verticalDrag)
                path.track(verticalDelta: 0, viewportHeight: 800, time: 0)
                let panSpeed = -48 * direction / duration
                for sample in 1...6 {
                    path.track(verticalDelta: -8 * direction, viewportHeight: 800,
                               time: duration * Double(sample) / 6, panSpeed: panSpeed)
                }
                // UIKit can still report the last moving velocity after a stationary hold.
                path.track(verticalDelta: 0, viewportHeight: 800, time: duration + pause, panSpeed: panSpeed)
                path.endTracking(cancelled: false)
                let stops = (0..<180).compactMap { _ in path.advance(by: 1.0 / 60, reduceMotion: false) }
                XCTAssertEqual(stops, [advances ? 2 + Int(direction) : 2])
            }
        }
    }

    func testShortFlickCanLiftAfterOneMovementSample() {
        var path = TransitPlayhead()
        path.reset(count: 3, selection: 0)
        path.beginTracking(input: .verticalDrag)
        path.track(verticalDelta: -48, viewportHeight: 800, time: 0, panSpeed: -1200)
        path.track(verticalDelta: 0, viewportHeight: 800, time: 0.012, panSpeed: -1200)
        path.endTracking(cancelled: false)
        XCTAssertEqual(path.advance(by: 2, reduceMotion: false), 1)
    }

    func testDragReversesImmediatelyAfterOverscrollAtFirstShot() {
        var path = TransitPlayhead()
        path.reset(count: 3, selection: 0)
        path.beginTracking(input: .verticalDrag)
        path.track(verticalDelta: 120, viewportHeight: 800, time: 0)
        _ = path.advance(by: 1, reduceMotion: false)
        let stretched = path.position
        path.track(verticalDelta: -60, viewportHeight: 800, time: 0.1)
        _ = path.advance(by: 1, reduceMotion: false)
        XCTAssertGreaterThan(path.position, stretched)
        XCTAssertLessThan(path.position, 0)
        path.track(verticalDelta: -120, viewportHeight: 800, time: 0.2)
        _ = path.advance(by: 1, reduceMotion: false)
        XCTAssertEqual(path.position, 0.1, accuracy: 0.0001)
    }

    func testEdgeResistanceHoldRegrabAndReturn() throws {
        for initial in [0, 3] {
            let direction = initial == 0 ? -1.0 : 1.0
            var path = TransitPlayhead()
            path.reset(count: 4, selection: initial)
            path.beginTracking(input: .verticalDrag)
            var stretches = [Double]()
            for pull in 1...4 {
                path.track(verticalDelta: -300 * direction, viewportHeight: 800, time: Double(pull))
                XCTAssertNil(path.advance(by: 1, reduceMotion: false))
                let span = try XCTUnwrap(path.span)
                XCTAssertEqual(span.lower, initial)
                XCTAssertEqual(span.upper, initial)
                stretches.append(Double(span.edgeStretch) * direction)
            }
            XCTAssertGreaterThan(stretches[0], 0.05)
            XCTAssertGreaterThan(stretches[3], stretches[2])
            XCTAssertLessThan(stretches[3] - stretches[2], stretches[1] - stretches[0])
            XCTAssertLessThan(stretches[3], 0.28)
            XCTAssertFalse(path.isMoving)
            path.endTracking(cancelled: false)
            _ = path.advance(by: 0.08, reduceMotion: false)
            let caught = path.position
            path.beginTracking()
            path.track(scale: 1, time: 5)
            _ = path.advance(by: 1, reduceMotion: false)
            XCTAssertEqual(path.position, caught, accuracy: 0.00001)
            path.endTracking(cancelled: true)
            let stops = (0..<120).compactMap { _ in path.advance(by: 1.0 / 60, reduceMotion: false) }
            XCTAssertEqual(stops, [initial])
            XCTAssertEqual(path.span?.edgeStretch, 0)
            XCTAssertFalse(path.isMoving)
        }
    }

    func testOnlyPinchingAddsEdgeLensTravelAndRegrabbingPreservesThePose() {
        for initial in [0, 3] {
            let direction = initial == 0 ? -1.0 : 1.0
            var path = TransitPlayhead()
            path.reset(count: 4, selection: initial)
            path.beginTracking(input: .verticalDrag)
            path.track(verticalDelta: -180 * direction, viewportHeight: 800, time: 0)
            _ = path.advance(by: 1, reduceMotion: false)
            let before = path.position
            XCTAssertEqual(path.edgeLensGain, 1)
            path.beginTracking(input: .pinch)
            XCTAssertEqual(path.edgeLensGain, 1, accuracy: 0.00001)
            XCTAssertEqual(path.position, before)
            path.track(scale: exp2(direction * 0.6), time: 0.2)
            _ = path.advance(by: 1, reduceMotion: false)
            XCTAssertGreaterThan(path.edgeLensGain, 1)

            path.reset(count: 4, selection: initial)
            path.beginTracking(input: .pinch)
            path.track(scale: exp2(direction * 0.3), time: 0)
            _ = path.advance(by: 1, reduceMotion: false)
            XCTAssertEqual(path.position, before, accuracy: 0.00001)
            XCTAssertGreaterThan(path.edgeLensGain, 1)
            let gain = path.edgeLensGain
            path.endTracking(cancelled: false)
            _ = path.advance(by: 0.08, reduceMotion: false)
            XCTAssertEqual(path.edgeLensGain, gain)
            path.beginTracking(input: .verticalDrag)
            XCTAssertEqual(path.edgeLensGain, gain)
        }
    }

    func testSinglePostEdgeWithReduceMotion() {
        var path = TransitPlayhead()
        path.reset(count: 1, selection: 0)
        path.beginTracking()
        path.track(scale: 2, time: 0.1)
        XCTAssertNil(path.advance(by: 1, reduceMotion: true))
        XCTAssertEqual(path.span?.edgeStretch, 0)
        path.endTracking(cancelled: false)
        XCTAssertEqual(path.advance(by: 1, reduceMotion: true), 0)
    }

    func testOutwardFlickReleasedBeforeFirstFrameReboundsOnSameShot() {
        for initial in [0, 2] {
            let sign = initial == 0 ? -1.0 : 1.0
            var path = TransitPlayhead()
            path.reset(count: 3, selection: initial)
            path.beginTracking(input: .verticalDrag)
            path.track(verticalDelta: -60 * sign, viewportHeight: 800, time: 0, panSpeed: -900 * sign)
            path.endTracking(cancelled: false)
            var peak = 0.0
            for _ in 0..<120 {
                _ = path.advance(by: 1.0 / 120, reduceMotion: false)
                XCTAssertEqual(path.span?.lower, initial)
                XCTAssertEqual(path.span?.upper, initial)
                peak = max(peak, sign * (path.position - Double(initial)))
            }
            XCTAssertGreaterThan(peak, 0.01)
            XCTAssertEqual(path.position, Double(initial))
            XCTAssertFalse(path.isMoving)
        }
    }

    func testReduceMotionUsesWholeShotsAndFeedReplacementClearsGesture() {
        var path = TransitPlayhead()
        path.reset(count: 4, selection: 1)
        path.beginTracking()
        path.track(scale: 1.6, time: 0.2)
        XCTAssertNil(path.advance(by: 1.0 / 60, reduceMotion: true))
        XCTAssertEqual(path.position, 2)
        path.endTracking(cancelled: false)
        XCTAssertEqual(path.advance(by: 1.0 / 60, reduceMotion: true), 2)
        path.reset(count: 0, selection: 2)
        XCTAssertNil(path.span)
        XCTAssertFalse(path.isMoving)
    }
}
