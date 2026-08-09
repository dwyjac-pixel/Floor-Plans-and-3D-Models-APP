import Foundation

/// Squares up a captured room outline: finds the dominant wall orientation,
/// snaps walls that are close to parallel/perpendicular onto it, and solves
/// the corners so the polygon stays closed. Corrects the small angle drift
/// that AR tracking introduces — most rooms really are 90° corners.
enum RoomSquarer {
    static func squared(_ points: [CornerRoom.Point], toleranceDegrees: Double = 12) -> [CornerRoom.Point] {
        let count = points.count
        guard count >= 3 else { return points }

        // Dominant orientation modulo 90°, weighted by wall length.
        var sumSin = 0.0
        var sumCos = 0.0
        for index in 0..<count {
            let a = points[index]
            let b = points[(index + 1) % count]
            let dx = b.x - a.x
            let dz = b.z - a.z
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.05 else { continue }
            let angle = atan2(dz, dx)
            sumSin += length * sin(4 * angle)
            sumCos += length * cos(4 * angle)
        }
        guard sumSin != 0 || sumCos != 0 else { return points }
        let theta = atan2(sumSin, sumCos) / 4

        // Rotate into the dominant frame.
        let cosForward = cos(-theta)
        let sinForward = sin(-theta)
        var x = points.map { $0.x * cosForward - $0.z * sinForward }
        var z = points.map { $0.x * sinForward + $0.z * cosForward }

        // Classify each wall in the rotated frame.
        enum WallClass {
            case horizontal, vertical, free
        }
        let tolerance = toleranceDegrees * .pi / 180
        var classes: [WallClass] = []
        for index in 0..<count {
            let next = (index + 1) % count
            let dx = x[next] - x[index]
            let dz = z[next] - z[index]
            var angle = abs(atan2(dz, dx))             // 0...π
            if angle > .pi / 2 { angle = .pi - angle } // 0...π/2
            if angle < tolerance {
                classes.append(.horizontal)
            } else if abs(angle - .pi / 2) < tolerance {
                classes.append(.vertical)
            } else {
                classes.append(.free)
            }
        }
        guard classes.contains(where: { if case .free = $0 { return false } else { return true } }) else {
            return points
        }

        // Iteratively enforce shared coordinates on snapped walls so the
        // polygon converges to a consistent rectilinear outline.
        for _ in 0..<16 {
            for index in 0..<count {
                let next = (index + 1) % count
                switch classes[index] {
                case .horizontal:
                    let mid = (z[index] + z[next]) / 2
                    z[index] = mid
                    z[next] = mid
                case .vertical:
                    let mid = (x[index] + x[next]) / 2
                    x[index] = mid
                    x[next] = mid
                case .free:
                    break
                }
            }
        }

        // Rotate back to world orientation.
        let cosBack = cos(theta)
        let sinBack = sin(theta)
        let result = (0..<count).map { index in
            CornerRoom.Point(x: x[index] * cosBack - z[index] * sinBack,
                             z: x[index] * sinBack + z[index] * cosBack)
        }

        // A near-collinear capture (a wall barely off-axis) can snap onto a
        // single line and collapse to a zero-area sliver. If squaring
        // destroyed the footprint, keep the original outline unchanged.
        func doubledArea(_ pts: [CornerRoom.Point]) -> Double {
            var doubled = 0.0
            for index in 0..<pts.count {
                let a = pts[index]
                let b = pts[(index + 1) % pts.count]
                doubled += a.x * b.z - b.x * a.z
            }
            return abs(doubled)
        }
        let inputArea = doubledArea(points)
        let squaredArea = doubledArea(result)
        if inputArea > 0.0002, squaredArea < inputArea * 0.25 {
            return points
        }
        return result
    }
}
