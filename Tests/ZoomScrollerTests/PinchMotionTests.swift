import XCTest
@testable import ZoomScroller

final class PinchMotionTests: XCTestCase {
    func testFlickCarriesFurtherThanSlowReleaseFromTheSameMidpoint() {
        for direction in [-1.0, 1.0] {
            for hz in [30, 60, 120] {
                func approach(duration: Double) -> PinchMotion {
                    var motion = PinchMotion(position: 8.5 - direction * 0.18, bounds: 0...15)
                    // The last input samples arrive between display updates.
                    for i in 0...6 {
                        let fraction = Double(i) / 6
                        motion.track(scale: exp2(direction * 0.18 * fraction), at: duration * fraction)
                    }
                    motion.release()
                    return motion
                }
                var slow = approach(duration: 0.9)
                var flick = approach(duration: 0.06)
                XCTAssertEqual(slow.position, flick.position)
                XCTAssertEqual(slow.target, direction > 0 ? 9 : 8)
                XCTAssertEqual(slow.target, flick.target)
                for _ in 0..<(hz / 6) {
                    _ = slow.advance(1.0 / Double(hz))
                    _ = flick.advance(1.0 / Double(hz))
                }
                XCTAssertGreaterThan(direction * (flick.position - slow.position), 0.10)
                for _ in 0..<(hz * 2) {
                    _ = flick.advance(1.0 / Double(hz))
                    XCTAssertGreaterThanOrEqual(direction * (flick.target - flick.position), 0)
                }
                XCTAssertEqual(flick.position, flick.target)
            }
        }
    }

    func testPauseBeforeLiftDiscardsFlickMomentum() {
        for direction in [-1.0, 1.0] {
            var motion = PinchMotion(position: 8, bounds: 0...15)
            motion.track(scale: 1, at: 0)
            let scale = exp2(direction * 0.24)
            motion.track(scale: scale, at: 0.06)
            var flick = motion
            flick.release()
            XCTAssertEqual(flick.target, 8 + direction)
            motion.track(scale: scale, at: 0.5)
            motion.release()
            XCTAssertEqual(motion.target, 8)
        }
    }

    func testSlowMidpointReleaseRemembersDirectionThroughPauseAndFingerLift() {
        for direction in [-1.0, 1.0] {
            let start = direction > 0 ? 8.0 : 9.0
            var motion = PinchMotion(position: start, bounds: 0...15)
            for sample in 1...240 {
                motion.track(scale: exp2(direction * 0.48 * Double(sample) / 240), at: Double(sample) / 120)
                _ = motion.advance(1.0 / 120)
            }
            for _ in 0..<120 { _ = motion.advance(1.0 / 120) }
            XCTAssertEqual(motion.velocity, 0)
            motion.track(scale: exp2(direction * 0.475), at: 3)
            motion.release()
            XCTAssertEqual(motion.target, start + direction)
        }
    }

    func testFinalReversalSelectsTheStopEvenBeforeTheNextDisplayFrame() {
        for direction in [-1.0, 1.0] {
            var motion = PinchMotion(position: 8.5, bounds: 0...15)
            motion.track(scale: exp2(-direction * 0.1), at: 0)
            _ = motion.advance(1.0 / 60)
            motion.track(scale: exp2(-direction * 0.05), at: 1.0 / 60)
            let atLift = motion.position
            motion.release()
            XCTAssertEqual(motion.position, atLift)
            XCTAssertEqual(motion.target, direction > 0 ? 9 : 8)
            var finished = false
            for _ in 0..<120 {
                let before = motion.position
                finished = motion.advance(1.0 / 60)
                XCTAssertGreaterThanOrEqual(direction * (motion.position - before), 0)
                if finished { break }
            }
            XCTAssertTrue(finished)
            XCTAssertEqual(motion.position, motion.target)
        }
    }

    func testFastReleaseNearAShotSettlesWithoutOvershoot() {
        for direction in [-1.0, 1.0] {
            var motion = PinchMotion(position: 8 - direction * 0.05, velocity: direction * 5, bounds: 0...15)
            motion.release()
            XCTAssertEqual(motion.target, 8)
            for _ in 0..<120 {
                _ = motion.advance(1.0 / 60)
                XCTAssertLessThanOrEqual(direction * (motion.position - 8), 0)
            }
            XCTAssertEqual(motion.position, 8)
        }
    }

    func testPauseReverseAndReleaseDuringOnePinch() {
        for frequency in [30, 60, 120] {
            let dt = 1.0 / Double(frequency)
            var motion = PinchMotion(position: 9, bounds: 0...18)
            for frame in 1...frequency {
                let phase = Double(frame) * dt
                motion.track(scale: exp2(0.52 * sin(phase * .pi / 2)), at: phase)
                _ = motion.advance(dt)
            }
            for _ in 0..<frequency { _ = motion.advance(dt) }
            XCTAssertEqual(motion.position, 9.52, accuracy: 0.0001)
            XCTAssertEqual(motion.velocity, 0)

            for frame in 1...(frequency / 3) {
                motion.track(scale: exp2(0.52 - 0.36 * Double(frame) * dt), at: 2 + Double(frame) * dt)
                _ = motion.advance(dt)
            }
            let atLift = motion.position, exitVelocity = motion.velocity
            XCTAssertLessThan(exitVelocity, -0.2)
            motion.release()
            XCTAssertEqual(motion.position, atLift)
            XCTAssertEqual(motion.velocity, exitVelocity)
            XCTAssertEqual(motion.target, 9)
            var finished = false
            for _ in 0..<(frequency * 2) {
                let before = motion.position
                finished = motion.advance(dt)
                XCTAssertLessThanOrEqual(motion.position, before)
                if finished { break }
            }
            XCTAssertTrue(finished)
            XCTAssertEqual(motion.position, 9)
            XCTAssertEqual(motion.velocity, 0)
        }
    }

    func testReverseImmediatelyAfterPullingPastEnd() {
        var motion = PinchMotion(position: 0, scale: 1.08, bounds: 0...18)
        motion.track(scale: 0.5, at: 0)
        let stretched = motion.target
        XCTAssertLessThan(stretched, 0)
        motion.track(scale: 0.55, at: 0.1)
        XCTAssertGreaterThan(motion.target, stretched)
        motion.track(scale: 1.08, at: 0.2)
        XCTAssertEqual(motion.target, 0, accuracy: 0.000001)
    }
}
