import Foundation

enum Measure {
    static func length(_ meters: Double, imperial: Bool) -> String {
        guard imperial else { return String(format: "%.2f m", meters) }
        let totalInches = meters * 39.37007874
        var feet = Int(totalInches / 12)
        var inches = Int(totalInches.truncatingRemainder(dividingBy: 12).rounded())
        if inches == 12 {
            feet += 1
            inches = 0
        }
        return "\(feet)' \(inches)\""
    }

    static func heightInFeetAndInches(_ meters: Double) -> (feet: Int, inches: Double) {
        let totalInches = (meters / 0.0254 * 100).rounded() / 100
        let feet = Int(totalInches / 12)
        return (feet, totalInches - Double(feet) * 12)
    }

    static func height(_ meters: Double, imperial: Bool) -> String {
        guard imperial else { return meters.formatted(.number.precision(.fractionLength(0...4))) + " m" }
        let (feet, inches) = heightInFeetAndInches(meters)
        return "\(feet)′ \(inches.formatted(.number.precision(.fractionLength(0...2))))″"
    }

    static func area(_ squareMeters: Double, imperial: Bool) -> String {
        imperial
            ? String(format: "%.0f sq ft", squareMeters * 10.7639)
            : String(format: "%.1f m²", squareMeters)
    }
}
