import Foundation

/// Shared tracking and release dynamics in stage coordinates.
struct PinchMotion {
    enum Input { case pinch, verticalDrag }

    private(set) var position: Double
    private(set) var velocity: Double
    private(set) var target: Double
    private(set) var tracking = true
    let bounds: ClosedRange<Double>
    private let input: Input
    private var previousScale: Double
    private var directionAnchor: Double
    private var lastDirection: FloatingPointSign?
    private var settleRate = 8.8
    private var sampleTime: TimeInterval?
    private var samplePosition: Double
    private var fingerVelocity = 0.0
    private var fingerPosition: Double
    private static let edgeLimit = 0.28
    private var edgeAtGrab: Double
    private let lensGainAtGrab: Float

    init(position: Double, velocity: Double = 0, scale: Double = 1, bounds: ClosedRange<Double>,
         input: Input = .pinch, inheritedEdgeGain: Float = 1) {
        self.position = position
        self.target = position
        self.velocity = velocity
        self.previousScale = scale
        self.directionAnchor = position
        self.samplePosition = position
        self.bounds = bounds
        self.input = input
        let edge = min(bounds.upperBound, max(bounds.lowerBound, position))
        let offset = position - edge
        edgeAtGrab = offset
        lensGainAtGrab = inheritedEdgeGain
        // Invert the resistance curve when a finger catches a returning edge.
        let ratio = min(0.95, abs(offset) / Self.edgeLimit)
        let travel = Self.edgeLimit * expm1(ratio / (1 - ratio))
        fingerPosition = edge + (offset < 0 ? -travel : travel)
    }

    var edgeLensGain: Float {
        let gain: Float = input == .pinch ? 1.24 : 1
        guard edgeAtGrab != 0 else { return gain }
        let edge = position - min(bounds.upperBound, max(bounds.lowerBound, position))
        guard edge * edgeAtGrab > 0 else { return gain }
        // Keep the camera pose at handoff. Only additional travel gets the new grip's gain.
        let retained = Float(min(1, abs(edgeAtGrab / edge)))
        return gain + retained * (lensGainAtGrab - gain)
    }

    mutating func track(scale: Double, at time: TimeInterval) {
        guard tracking, scale.isFinite, scale > 0 else { return }
        let delta = log2(scale / previousScale)
        previousScale = scale
        track(delta: delta, at: time)
    }

    mutating func track(delta: Double, at time: TimeInterval, panSpeed: Double? = nil) {
        guard tracking, delta.isFinite else { return }
        fingerPosition += delta
        let edge = min(bounds.upperBound, max(bounds.lowerBound, fingerPosition))
        let overrun = fingerPosition - edge
        if overrun == 0 {
            target = edge
        } else {
            let strain = log1p(abs(overrun) / Self.edgeLimit)
            let stretch = Self.edgeLimit * (strain / (1 + strain))
            target = edge + (overrun < 0 ? -stretch : stretch)
        }

        // Follow the furthest finger position in the current direction. A reversal
        // must travel 0.015 stages, even over many slow samples.
        let travel = target - directionAnchor
        if travel != 0 && (travel.sign == lastDirection || abs(travel) >= 0.015) {
            lastDirection = travel.sign
            directionAnchor = target
        }

        // Both inputs use stages per second. A stationary lift also samples the pause.
        if let panSpeed, sampleTime == nil || delta != 0 {
            // UIKit measures points per second before the pan officially begins.
            // Its filtered estimate is more reliable than two callbacks on a short flick.
            fingerVelocity = min(6, max(-6, panSpeed))
        } else if let sampleTime {
            let dt = time - sampleTime
            guard dt >= 0.001 else { return } // Accumulate coalesced events.
            let speed = min(6, max(-6, (target - samplePosition) / dt))
            fingerVelocity += (speed - fingerVelocity) * (1 - exp(-dt / 0.035))
        }
        sampleTime = time
        samplePosition = target
    }

    mutating func release(destination: Double? = nil) {
        if !bounds.contains(target) {
            let edge = min(bounds.upperBound, max(bounds.lowerBound, target))
            if destination == nil || destination == edge {
                // Carry a quick pull through lift, then spring back to this shot.
                // Bound the inward tangent so the rebound never opens the next shot.
                let outward = target < edge ? -1.0 : 1.0
                let extensionAtLift = (position - edge) * outward
                settleRate = 14
                if extensionAtLift >= 0 {
                    let pull = max(velocity * outward, min(2, (target - position) * outward * 32))
                    velocity = outward * min(settleRate * (Self.edgeLimit - extensionAtLift),
                                             max(-settleRate * extensionAtLift, pull))
                }
                target = edge
                tracking = false
                return
            }
        }
        let fraction = target - floor(target)
        var stop = target.rounded()
        if destination == nil, let lastDirection {
            let speed = fingerVelocity.sign == lastDirection ? fingerVelocity : 0
            // A brisk one-finger release needs only 3% of a stage after recognition.
            // Apply this extra reach at lift so pauses and slow scrubs stay precise.
            let ramp = input == .verticalDrag ? (abs(speed) - 0.25) / 0.55 : (abs(speed) - 0.15) / 2.0
            let u = min(1, max(0, ramp))
            let flick = u * u * (3 - 2 * u)
            settleRate = 7.0 + 4.5 * flick
            // A flick can commit a little earlier, but only to the adjacent shot.
            let reach = (input == .verticalDrag ? 0.27 : 0.12) * flick
            if lastDirection == .plus && fraction >= 0.3 - reach {
                stop = ceil(target)
            } else if lastDirection == .minus && fraction <= 0.7 + reach {
                stop = floor(target)
            }
            // Follow a late acceleration between display frames. When the
            // visible camera already matches the fingers, keep its tangent.
            if abs(speed - velocity) > 0.12 {
                velocity += 0.75 * (speed - velocity)
            }
        }
        target = min(bounds.upperBound, max(bounds.lowerBound, destination?.rounded() ?? stop))
        // Carry the visible velocity into the spring when it points toward the
        // stop. The critical-damping limit keeps a fast release from passing it.
        let distance = target - position
        let limit = settleRate * distance
        if velocity * distance <= 0 {
            velocity = 0
        } else if abs(velocity) > abs(limit) {
            velocity = limit
        }
        tracking = false
    }

    /// Closed-form critically damped response in stage coordinates.
    mutating func advance(_ dt: Double) -> Bool {
        let rate = tracking ? 65.0 : settleRate
        let offset = position - target
        let slope = velocity + rate * offset
        let decay = exp(-rate * dt)
        position = target + (offset + slope * dt) * decay
        if bounds.contains(position) { edgeAtGrab = 0 }
        velocity = (velocity - rate * slope * dt) * decay
        let lower = bounds.lowerBound - Self.edgeLimit, upper = bounds.upperBound + Self.edgeLimit
        if position < lower || position > upper {
            position = min(upper, max(lower, position))
            velocity = 0
        }
        if abs(position - target) < 0.00005 && abs(velocity) < 0.0006 {
            position = target
            velocity = 0
            return !tracking
        }
        return false
    }
}
