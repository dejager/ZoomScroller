import Foundation

/// A whole position is a settled shot. A fractional position exposes two neighbors.
struct TransitSpan: Equatable {
    let lower, upper: Int
    let progress: Float
    let edgeStretch: Float

    init?(position: Double, count: Int) {
        guard count > 0 else { return nil }
        let bounded = min(Double(count - 1), max(0, position))
        edgeStretch = Float(position - bounded)
        lower = Int(bounded)
        progress = Float(bounded - Double(lower))
        upper = progress == 0 ? lower : min(lower + 1, count - 1)
    }
}

struct TransitPlayhead {
    private(set) var count = 0
    private(set) var position = 0.0
    private var motion: PinchMotion?

    var span: TransitSpan? { TransitSpan(position: position, count: count) }
    var isMoving: Bool {
        guard let motion else { return false }
        return !motion.tracking || motion.target != motion.position || motion.velocity != 0
    }
    var isTracking: Bool { motion?.tracking == true }
    var edgeLensGain: Float { motion?.edgeLensGain ?? 1 }

    mutating func seek(to value: Double) {
        position = min(Double(max(0, count - 1)), max(0, value.isFinite ? value : 0))
        motion = nil
    }

    mutating func reset(count: Int, selection: Int) {
        self.count = count
        position = Double(clamped(selection))
        motion = nil
    }

    func clamped(_ index: Int) -> Int { min(max(0, count - 1), max(0, index)) }

    mutating func beginTracking(input: PinchMotion.Input = .pinch) {
        guard count > 0 else { return }
        motion = PinchMotion(position: position, velocity: motion?.velocity ?? 0,
                             bounds: 0...Double(count - 1), input: input, inheritedEdgeGain: edgeLensGain)
    }

    mutating func track(scale: Double, time: Double) {
        motion?.track(scale: scale, at: time)
    }

    mutating func track(verticalDelta: Double, viewportHeight: Double, time: Double, panSpeed: Double? = nil) {
        guard viewportHeight > 0 else { return }
        // Three quarters of the canvas traverses one shot, independent of screen size.
        let pointsPerStage = 0.75 * viewportHeight
        motion?.track(delta: -verticalDelta / pointsPerStage, at: time, panSpeed: panSpeed.map { -$0 / pointsPerStage })
    }

    mutating func endTracking(cancelled: Bool) {
        guard motion?.tracking == true else { return }
        motion?.release(destination: cancelled ? position.rounded() : nil)
    }

    mutating func navigate(to index: Int, animated: Bool) {
        let destination = Double(clamped(index))
        // Distant programmatic jumps shouldn't start decoders for intervening items.
        guard animated, count > 1, abs(destination - position) <= 1.001, position != destination else {
            position = destination
            motion = nil
            return
        }
        beginTracking()
        motion?.release(destination: destination)
    }

    /// Returns a selection only when the gesture or navigation arrives at a stop.
    mutating func advance(by seconds: Double, reduceMotion: Bool) -> Int? {
        guard var current = motion else { return nil }
        if reduceMotion {
            position = current.target.rounded()
            if current.tracking { return nil }
        } else {
            let arrived = current.advance(max(0, seconds))
            position = current.position
            if !arrived {
                motion = current
                return nil
            }
        }
        motion = nil
        return Int(position)
    }
}
