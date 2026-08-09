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

    static func area(_ squareMeters: Double, imperial: Bool) -> String {
        imperial
            ? String(format: "%.0f sq ft", squareMeters * 10.7639)
            : String(format: "%.1f m²", squareMeters)
    }
}
